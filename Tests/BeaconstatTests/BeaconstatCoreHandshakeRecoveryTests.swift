import XCTest
@testable import Beaconstat

/// C1 — a single handshake failure permanently disabled the SDK for the whole
/// app run. `performHandshakeAndInstall()` was called exactly once, from
/// `configure()`; on failure it only logged. `siteToken` was assigned only in
/// the success branch, `flushInternal` hard-guarded on it, and neither the flush
/// timer nor the reachability reconnect ever retried the handshake. The token
/// persisted to `SecureStoreKey.siteToken` was never read back by anything.
///
/// Failure scenario: cold launch with no signal. `session_started`,
/// `install_detected` and `app_updated` were never even enqueued; user events
/// piled up and were evicted at the 500 cap; Wi-Fi returning five seconds later
/// changed nothing.
final class BeaconstatCoreHandshakeRecoveryTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func core(file: URL, store: SecureStore = InMemorySecureStore(),
                      reachability: Reachability? = nil) -> BeaconstatCore {
        BeaconstatCore(store: store,
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app",
                       queueFileURL: file,
                       reachabilityFactory: { _ in reachability })
    }

    @discardableResult
    private func configure(_ c: BeaconstatCore, flushInterval: TimeInterval = 3600,
                           environment: [String: String] = ["device.platform": "ios"]) -> BeaconstatCore {
        var o = BeaconstatOptions(); o.flushInterval = flushInterval
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: environment)
        return c
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow", timeout: TimeInterval = 3) {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: timeout)
    }

    private func eventsRequests() -> [URLRequest] {
        MockURLProtocol.capturedRequests.filter { $0.url!.path.hasSuffix("/events") }
    }

    private func handshakeCount() -> Int {
        MockURLProtocol.capturedRequests.filter { $0.url!.path.hasSuffix("/handshake") }.count
    }

    private func sentBodies() -> String {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
    }

    private func tempQueue() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
    }

    /// (a) The persisted token must be read back at `configure()`, so a device
    /// that handshook successfully once keeps working offline.
    func testAPersistedSiteTokenKeepsTheSDKSendingWhenTheHandshakeFails() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 0, data: Data(), error: URLError(.notConnectedToInternet))
                : .init(statusCode: 202)
        }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = InMemorySecureStore()
        store.set("bcs_tok_cached", forKey: .siteToken) // from a previous successful run
        let c = configure(core(file: file, store: store))
        c.track("feature_used", properties: [:])
        c.flush()
        drain(c)

        let events = eventsRequests()
        XCTAssertFalse(events.isEmpty, "the whole run was disabled by one handshake failure")
        XCTAssertEqual(events.first?.value(forHTTPHeaderField: "x-site-token"), "bcs_tok_cached")
        XCTAssertTrue(sentBodies().contains("feature_used"))
    }

    /// The launch events must be enqueued locally even when the handshake never
    /// completes, so they survive to a later successful flush.
    func testLaunchEventsAreEnqueuedEvenWhenTheHandshakeFails() {
        MockURLProtocol.handler = { _ in .init(statusCode: 0, data: Data(), error: URLError(.timedOut)) }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = InMemorySecureStore()
        store.set("1", forKey: .hasEmittedInstall)   // existing install…
        store.set("1.0.0", forKey: .lastKnownVersion) // …that just updated
        store.set("1", forKey: .lastKnownBuild)
        let c = configure(core(file: file, store: store),
                          environment: ["device.platform": "ios", "app.version": "2.0.0", "app.build": "9"])
        c.track("feature_used", properties: [:])
        drain(c)

        let queued = FileEventStore(fileURL: file).load().map(\.name)
        XCTAssertTrue(queued.contains("_bcs.session_started"), "\(queued)")
        XCTAssertTrue(queued.contains("_bcs.apple.app_updated"), "\(queued)")
        XCTAssertTrue(queued.contains("feature_used"), "\(queued)")
    }

    func testInstallDetectedIsEnqueuedEvenWhenTheHandshakeFails() {
        MockURLProtocol.handler = { _ in .init(statusCode: 0, data: Data(), error: URLError(.timedOut)) }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = configure(core(file: file))
        drain(c)
        let queued = FileEventStore(fileURL: file).load().map(\.name)
        XCTAssertEqual(queued, ["_bcs.session_started", "_bcs.install_detected"])
    }

    /// (b) The reconnect trigger must retry the handshake, not just the flush.
    /// This is the exact scenario the review described: subway launch, Wi-Fi back
    /// five seconds later.
    func testReconnectRetriesTheHandshakeAndDrainsTheQueue() {
        var handshakeShouldFail = true
        MockURLProtocol.handler = { req in
            guard req.url!.path.hasSuffix("/handshake") else { return .init(statusCode: 202) }
            if handshakeShouldFail {
                return .init(statusCode: 0, data: Data(), error: URLError(.notConnectedToInternet))
            }
            return .init(statusCode: 200,
                         data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
        }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let reachability = ManualReachability()
        let c = configure(core(file: file, reachability: reachability))
        drain(c, "offline launch")
        XCTAssertTrue(eventsRequests().isEmpty)
        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty, "events should be waiting on disk")

        handshakeShouldFail = false
        reachability.simulateReconnect()
        drain(c, "after reconnect")

        XCTAssertFalse(eventsRequests().isEmpty, "reconnect did not re-handshake")
        XCTAssertTrue(sentBodies().contains("_bcs.install_detected"))
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty, "queue not drained after recovery")
    }

    /// The explicit `flush()` trigger must recover too — a host calling `flush()`
    /// after a failed launch handshake should not be silently ignored.
    func testFlushRetriesTheHandshake() {
        var handshakeShouldFail = true
        MockURLProtocol.handler = { req in
            guard req.url!.path.hasSuffix("/handshake") else { return .init(statusCode: 202) }
            if handshakeShouldFail {
                return .init(statusCode: 0, data: Data(), error: URLError(.networkConnectionLost))
            }
            return .init(statusCode: 200,
                         data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
        }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = configure(core(file: file))
        drain(c, "offline launch")
        let handshakesAfterLaunch = handshakeCount()

        handshakeShouldFail = false
        c.flush()
        drain(c, "after flush")

        XCTAssertGreaterThan(handshakeCount(), handshakesAfterLaunch, "flush() did not re-handshake")
        XCTAssertTrue(sentBodies().contains("_bcs.install_detected"))
    }

    /// A failed handshake must schedule the same backoff round a failed send
    /// does, so recovery does not have to wait for the periodic timer (4 hours in
    /// Release).
    func testFailedHandshakeSchedulesABackoffRetryWithNoExternalTrigger() {
        var handshakeShouldFail = true
        MockURLProtocol.handler = { req in
            guard req.url!.path.hasSuffix("/handshake") else { return .init(statusCode: 202) }
            if handshakeShouldFail {
                return .init(statusCode: 0, data: Data(), error: URLError(.cannotConnectToHost))
            }
            return .init(statusCode: 200,
                         data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
        }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = configure(core(file: file))
        drain(c, "offline launch")
        XCTAssertTrue(eventsRequests().isEmpty)

        // No reconnect, no flush(), no reconfigure: only the backoff timer
        // (first attempt is RetryPolicy's 2s) may recover this.
        handshakeShouldFail = false
        let recovered = expectation(description: "recovered by backoff")
        pollUntil(deadline: Date().addingTimeInterval(6),
                  condition: { !self.eventsRequests().isEmpty },
                  fulfil: recovered)
        wait(for: [recovered], timeout: 8)
        XCTAssertTrue(sentBodies().contains("_bcs.install_detected"))
    }

    /// A 401 handshake means bad credentials; retrying is pointless and noisy.
    func testUnauthorizedHandshakeHaltsInsteadOfRetrying() {
        MockURLProtocol.handler = { _ in .init(statusCode: 401) }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = configure(core(file: file))
        drain(c, "launch")
        let afterLaunch = handshakeCount()
        c.flush()
        c.track("feature_used", properties: [:])
        c.flush()
        drain(c, "after flushes")
        XCTAssertEqual(handshakeCount(), afterLaunch, "kept hammering a rejected key")
    }

    /// Only ever one handshake in flight, however many triggers coincide.
    func testConcurrentTriggersCollapseIntoOneHandshake() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = configure(core(file: file))
        for _ in 0..<10 { c.flush() }
        drain(c)
        XCTAssertEqual(handshakeCount(), 1)
    }

    private func pollUntil(deadline: Date, condition: @escaping () -> Bool, fulfil: XCTestExpectation) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            if condition() { return fulfil.fulfill() }
            guard Date() < deadline else { return }
            self.pollUntil(deadline: deadline, condition: condition, fulfil: fulfil)
        }
    }
}

/// A `Reachability` a test drives by hand. Counts start/stop so teardown and
/// restart (M14) are observable, not just "did it ever start".
final class ManualReachability: Reachability {
    var onReconnect: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func simulateReconnect() { onReconnect?() }
}
