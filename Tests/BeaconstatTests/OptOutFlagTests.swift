import XCTest
@testable import Beaconstat

// `CountingSecureStore` and `GatedSecureStore` used to live here as
// file-scoped helpers; they now live in `TestSupport.swift`, because the
// questions they answer come up all over the suite.

/// M4 — `optOut()` wrote the flag via `queue.async` while the public getter read
/// secure storage **synchronously on the caller's thread**, so
/// `optOut(); assert(isOptedOut)` failed intermittently. It was also the only
/// place in the SDK that touched `store` off the serial queue.
///
/// M5 — that same getter was consulted on enqueue, on flush and at all seven
/// public entry points, so every `track()` cost at least two Keychain round
/// trips, and a SwiftUI `body` reading `Beaconstat.isOptedOut` did one per
/// re-evaluation, on main.
final class OptOutFlagTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func tempQueue() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
    }

    private func handshake202() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
    }

    private func core(file: URL, store: SecureStore) -> BeaconstatCore {
        BeaconstatCore(store: store,
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app",
                       queueFileURL: file, reachabilityFactory: { _ in nil })
    }

    private func configure(_ c: BeaconstatCore) {
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow") {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func sentBodies() -> String {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events")
                ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
    }

    // MARK: - M4: the getter cannot lag the call

    /// The review's scenario, made deterministic: the serial queue is parked
    /// inside the flag write, so pre-fix the getter provably saw the old value.
    func testIsOptedOutIsTrueBeforeTheQueueHasPersistedIt() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = GatedSecureStore(gating: .optedOut)
        let c = core(file: file, store: store)
        configure(c); drain(c, "configured")

        store.arm()
        c.optOut()
        store.waitUntilEntered() // the queue is now parked mid-write
        XCTAssertTrue(c.isOptedOut,
                      "the kill switch must read as engaged the instant optOut() returns")
        store.releaseGate()
        drain(c, "opted out")
        c.shutdown()
    }

    func testIsOptedOutIsFalseBeforeTheQueueHasPersistedTheOptIn() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = GatedSecureStore(gating: .optedOut)
        let c = core(file: file, store: store)
        configure(c); drain(c, "configured")
        c.optOut(); drain(c, "opted out")

        store.arm()
        c.optIn()
        store.waitUntilEntered()
        XCTAssertFalse(c.isOptedOut)
        store.releaseGate()
        drain(c, "opted in")
        c.shutdown()
    }

    /// The plain sequence a host actually writes, with no gate at all.
    func testGetterAgreesWithTheLastCallImmediately() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file, store: InMemorySecureStore())
        configure(c)
        for _ in 0..<50 {
            c.optOut()
            XCTAssertTrue(c.isOptedOut)
            c.optIn()
            XCTAssertFalse(c.isOptedOut)
        }
        drain(c)
        c.shutdown()
    }

    /// A flag persisted by a previous launch must be visible without a
    /// `configure()` — the host may check consent before setting the SDK up.
    func testAPersistedFlagIsVisibleOnAFreshCore() {
        let store = InMemorySecureStore(); store.set("1", forKey: .optedOut)
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file, store: store)
        XCTAssertTrue(c.isOptedOut)
        c.shutdown()
    }

    func testNoPersistedFlagReadsAsOptedIn() {
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file, store: InMemorySecureStore())
        XCTAssertFalse(c.isOptedOut)
        c.shutdown()
    }

    /// The decision still has to outlive the process.
    func testOptOutIsPersistedToSecureStorage() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = InMemorySecureStore()
        let c = core(file: file, store: store)
        configure(c); drain(c, "configured")
        c.optOut(); drain(c, "opted out")
        XCTAssertNotNil(store.string(forKey: .optedOut))
        c.optIn(); drain(c, "opted in")
        XCTAssertNil(store.string(forKey: .optedOut))
        c.shutdown()
    }

    // MARK: - M5: the flag is not re-read per event

    func testTrackingManyEventsDoesNotQueryTheStoreForTheOptOutFlag() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = CountingSecureStore()
        let c = core(file: file, store: store)
        configure(c); drain(c, "configured")

        store.resetCounts()
        for i in 0..<25 { c.track("feature_used", properties: ["i": "\(i)"]) }
        c.flush()
        drain(c, "tracked")

        XCTAssertEqual(store.reads(of: .optedOut), 0,
                       "the opt-out flag must be served from memory, not the Keychain")
        c.shutdown()
    }

    /// A SwiftUI settings view re-evaluating its `body` must not pay for a
    /// Keychain round trip per read, on main.
    func testRepeatedPublicGetterReadsDoNotQueryTheStore() {
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = CountingSecureStore()
        let c = core(file: file, store: store)
        drain(c, "primed")        // let the one priming read land
        store.resetCounts()
        for _ in 0..<500 { _ = c.isOptedOut }
        XCTAssertEqual(store.reads(of: .optedOut), 0)
        c.shutdown()
    }

    /// Priming must be one read for the whole process, not one per consultation.
    func testTheFlagIsReadFromStorageAtMostOncePerProcess() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let store = CountingSecureStore()
        let c = core(file: file, store: store)
        configure(c); drain(c, "configured")
        for i in 0..<10 { c.track("feature_used", properties: ["i": "\(i)"]) }
        c.trackShortcut("com.example.newItem")
        c.trackWidget(kind: "TodayWidget", family: "systemSmall")
        c.trackPushReceived(category: "MESSAGE", wasSilent: false)
        c.flush()
        drain(c, "tracked")
        XCTAssertLessThanOrEqual(store.reads(of: .optedOut), 1)
        c.shutdown()
    }

    // MARK: - the cache must never leak events in either direction

    /// A stale `false` must not let an event through after `optOut()`.
    func testNothingIsCollectedAfterOptOutEvenImmediately() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file, store: InMemorySecureStore())
        configure(c); drain(c, "configured")
        MockURLProtocol.reset(); handshake202()

        c.optOut()
        c.track("after_opt_out", properties: [:])
        c.trackShortcut("com.example.newItem")
        c.trackOpenURL(URL(string: "myapp://home")!)
        c.trackPushOpened(category: "MESSAGE", actionId: "REPLY")
        c.flush()
        drain(c, "opted out")

        XCTAssertFalse(sentBodies().contains("after_opt_out"))
        XCTAssertFalse(sentBodies().contains("opened_from_shortcut"))
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty)
        c.shutdown()
    }

    /// A stale `true` must not keep suppressing events after `optIn()`.
    func testCollectionResumesImmediatelyAfterOptIn() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file, store: InMemorySecureStore())
        configure(c); drain(c, "configured")
        c.optOut(); drain(c, "opted out")
        MockURLProtocol.reset(); handshake202()

        c.optIn()
        c.track("after_opt_in", properties: [:])
        c.flush()
        drain(c, "opted in")
        XCTAssertTrue(sentBodies().contains("after_opt_in"), sentBodies())
        c.shutdown()
    }
}
