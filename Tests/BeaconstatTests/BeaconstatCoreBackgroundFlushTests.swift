import XCTest
@testable import Beaconstat

/// Spy for the background assertion. Thread-safe because `begin` is called on
/// the notification thread and `end` on the core's serial queue.
final class SpyBackgroundActivity: BackgroundActivity, @unchecked Sendable {
    private let lock = NSLock()
    private var beginCount = 0
    private var endCount = 0
    private var expiration: (() -> Void)?

    var begins: Int { lock.lock(); defer { lock.unlock() }; return beginCount }
    var ends: Int { lock.lock(); defer { lock.unlock() }; return endCount }
    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return beginCount > endCount }

    func begin(expiration: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard beginCount == endCount else { return } // idempotent, like the real one
        beginCount += 1
        self.expiration = expiration
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        guard beginCount > endCount else { return }
        endCount += 1
    }

    /// Simulates the OS reclaiming the time before the flush finished.
    func fireExpiration() {
        lock.lock(); let block = expiration; lock.unlock()
        block?()
    }
}

/// H2 — `flushOnBackground` is on by default and starts a POST at exactly the
/// moment iOS is about to suspend the process.
final class BeaconstatCoreBackgroundFlushTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
    }

    private func core(file: URL, activity: BackgroundActivity,
                      observer: LifecycleObserver) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app", queueFileURL: file,
                       reachabilityFactory: { _ in nil },
                       lifecycleObserver: observer,
                       backgroundActivity: activity)
    }

    private func configure(_ core: BeaconstatCore) {
        var options = BeaconstatOptions()
        options.flushInterval = 3600
        options.batchSize = 10_000 // never trip the size trigger; drive flushes explicitly
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: ["device.platform": "ios"])
    }

    private func settle(_ core: BeaconstatCore) {
        let done = expectation(description: "quiescent")
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// The review's exact scenario: a first run whose very first send is cut off
    /// mid-flight. `dequeueBatch` used to rewrite `queue.json` without the batch
    /// before the POST, so `session_started` and `install_detected` were gone
    /// from disk *and* from memory the moment the process was suspended.
    func testFirstRunLaunchEventsSurviveASuspensionMidSend() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
        }
        let file = tempURL(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let core = core(file: file, activity: SpyBackgroundActivity(), observer: observer)
        // Park the /events response before anything is sent, so the batch that
        // install_detected flushes immediately is the one left in flight.
        MockURLProtocol.holdEventsUntilReleased = true
        configure(core)
        MockURLProtocol.waitForHeldEventsRequest()

        // The process would be suspended and jetsammed here. Read the file the
        // way a cold relaunch would.
        let onDisk = FileEventStore(fileURL: file).load().map(\.name)
        XCTAssertTrue(onDisk.contains("_bcs.session_started"),
                      "session_started must survive an interrupted send: \(onDisk)")
        XCTAssertTrue(onDisk.contains("_bcs.install_detected"),
                      "install_detected must survive an interrupted send: \(onDisk)")

        MockURLProtocol.releaseHeldEventsRequest()
        settle(core)
        core.shutdown()
    }

    /// The same property for events tracked later in the run, driven through
    /// the real `didEnterBackground` path.
    func testBackgroundBatchSurvivesASuspensionMidSend() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
        }
        let file = tempURL(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let core = core(file: file, activity: SpyBackgroundActivity(), observer: observer)
        configure(core)
        settle(core)
        core.track("feature_used", properties: ["a": "b"])
        settle(core)

        MockURLProtocol.holdEventsUntilReleased = true
        observer.onBackground?()
        MockURLProtocol.waitForHeldEventsRequest()

        let onDisk = FileEventStore(fileURL: file).load().map(\.name)
        XCTAssertTrue(onDisk.contains("feature_used"),
                      "the in-flight batch must still be on disk: \(onDisk)")
        XCTAssertTrue(onDisk.contains("_bcs.apple.app_backgrounded"),
                      "including the event that triggered the flush: \(onDisk)")

        MockURLProtocol.releaseHeldEventsRequest()
        settle(core)
        core.shutdown()
    }

    /// ...and once the server does acknowledge, the file is emptied — the fix
    /// must not trade data loss for permanent duplication.
    func testAcknowledgedBackgroundFlushEmptiesTheFile() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
        }
        let file = tempURL(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let core = core(file: file, activity: SpyBackgroundActivity(), observer: observer)
        configure(core)
        settle(core)
        core.track("feature_used", properties: [:])
        settle(core)
        observer.onBackground?()
        settle(core)
        XCTAssertEqual(FileEventStore(fileURL: file).load(), [], "acknowledged events are gone")
        core.shutdown()
    }

    func testBackgroundTransitionTakesAndReleasesAnAssertion() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
        }
        let file = tempURL(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let activity = SpyBackgroundActivity()
        let core = core(file: file, activity: activity, observer: observer)
        configure(core)
        settle(core)
        core.track("feature_used", properties: [:])
        settle(core)

        observer.onBackground?()
        settle(core)
        XCTAssertGreaterThanOrEqual(activity.begins, 1, "a background flush must assert background time")
        XCTAssertFalse(activity.isHeld, "and must give it back once the send completes")
        core.shutdown()
    }

    /// The assertion has to outlive the request, not just the call that started
    /// it — releasing it at the end of `handleBackground()` would defeat it.
    func testAssertionIsHeldForTheDurationOfTheSend() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
        }
        let file = tempURL(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let activity = SpyBackgroundActivity()
        let core = core(file: file, activity: activity, observer: observer)
        configure(core)
        settle(core)
        core.track("feature_used", properties: [:])
        settle(core)

        MockURLProtocol.holdEventsUntilReleased = true
        observer.onBackground?()
        MockURLProtocol.waitForHeldEventsRequest()
        XCTAssertTrue(activity.isHeld, "still sending — the process must still be held awake")

        MockURLProtocol.releaseHeldEventsRequest()
        settle(core)
        XCTAssertFalse(activity.isHeld)
        core.shutdown()
    }

    /// Expiry is not an error path that loses anything: the batch was never
    /// acknowledged, so it is still on disk.
    func testExpiryLeavesTheBatchQueued() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
        }
        let file = tempURL(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let activity = SpyBackgroundActivity()
        let core = core(file: file, activity: activity, observer: observer)
        configure(core)
        settle(core)
        core.track("feature_used", properties: [:])
        settle(core)

        MockURLProtocol.holdEventsUntilReleased = true
        observer.onBackground?()
        MockURLProtocol.waitForHeldEventsRequest()
        activity.fireExpiration()

        XCTAssertTrue(FileEventStore(fileURL: file).load().contains { $0.name == "feature_used" })
        MockURLProtocol.releaseHeldEventsRequest()
        settle(core)
        core.shutdown()
    }

    /// `flushOnBackground: false` must not leave an assertion dangling — the
    /// observer takes it unconditionally, so the core has to give it back.
    func testAssertionIsReleasedWhenBackgroundFlushIsDisabled() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
        }
        let file = tempURL(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let activity = SpyBackgroundActivity()
        let core = core(file: file, activity: activity, observer: observer)
        var options = BeaconstatOptions()
        options.flushInterval = 3600
        options.flushOnBackground = false
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: ["device.platform": "ios"])
        settle(core)

        observer.onBackground?()
        settle(core)
        XCTAssertFalse(activity.isHeld, "no flush was started, so nothing should be held")
        core.shutdown()
    }

    /// Coming back to the foreground releases the assertion: the host may want
    /// its background time for its own work.
    func testForegroundReleasesTheAssertion() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
        }
        let file = tempURL(); defer { try? FileManager.default.removeItem(at: file) }
        let observer = LifecycleObserver()
        let activity = SpyBackgroundActivity()
        let core = core(file: file, activity: activity, observer: observer)
        configure(core)
        settle(core)
        core.track("feature_used", properties: [:])
        settle(core)

        MockURLProtocol.holdEventsUntilReleased = true
        observer.onBackground?()
        MockURLProtocol.waitForHeldEventsRequest()
        XCTAssertTrue(activity.isHeld)

        observer.onForeground?()
        let released = expectation(description: "released")
        // onForeground hops onto the serial queue; poll briefly rather than sleep.
        DispatchQueue.global().async {
            for _ in 0..<200 where activity.isHeld { usleep(5_000) }
            released.fulfill()
        }
        wait(for: [released], timeout: 3)
        XCTAssertFalse(activity.isHeld)

        MockURLProtocol.releaseHeldEventsRequest()
        settle(core)
        core.shutdown()
    }
}
