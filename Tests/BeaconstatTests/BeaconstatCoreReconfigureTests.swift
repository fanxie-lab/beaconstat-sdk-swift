import XCTest
@testable import Beaconstat

/// Fulfils an expectation when its `URLSession` is invalidated, so a test can
/// prove the previous session was released rather than leaked.
private final class InvalidationWitness: NSObject, URLSessionDelegate {
    let invalidated = XCTestExpectation(description: "URLSession invalidated")
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        invalidated.fulfill()
    }
}

/// M7 — reconfigure silently ignored new options and leaked the previous
/// `URLSession`. `queue_` and `sessionManager` were only built `if … == nil`, so
/// a second `configure()` kept the old `maxQueuedEvents` / `sessionTimeout` with
/// no warning, while a *new* `URLSession` was built every time and the old one
/// was never invalidated — and `URLSession` retains itself until invalidated, so
/// each reconfigure leaked a session plus its delegate queue. There was no
/// `shutdown()` and no way to release anything.
final class BeaconstatCoreReconfigureTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func handshake503() {
        // Handshake succeeds, events are never acked, so the queue keeps filling.
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 503)
        }
    }

    private func handshake202() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
    }

    private func tempQueue() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow") {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    private func configure(_ c: BeaconstatCore, _ mutate: (inout BeaconstatOptions) -> Void = { _ in }) {
        var o = BeaconstatOptions(); o.flushInterval = 3600
        mutate(&o)
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
    }

    // MARK: - reconfigure honours the new options

    func testReconfigureAppliesTheNewMaxQueuedEvents() {
        handshake503()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = BeaconstatCore(store: InMemorySecureStore(), clock: SystemClock(),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: file, reachabilityFactory: { _ in nil })
        configure(c) { $0.maxQueuedEvents = 500 }
        drain(c, "first configure")
        for i in 0..<20 { c.track("e\(i)", properties: [:]) }
        drain(c, "filled")
        XCTAssertGreaterThan(FileEventStore(fileURL: file).load().count, 5)

        configure(c) { $0.maxQueuedEvents = 3 } // tighten the cap
        drain(c, "reconfigured")
        XCTAssertLessThanOrEqual(FileEventStore(fileURL: file).load().count, 3,
                                 "the new maxQueuedEvents was silently ignored")
    }

    func testReconfigureAppliesTheNewSessionTimeout() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let clock = SteppableClock(Date(timeIntervalSince1970: 1_776_594_600))
        let c = BeaconstatCore(store: InMemorySecureStore(), clock: clock,
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: file, reachabilityFactory: { _ in nil })
        configure(c) { $0.sessionTimeout = 86_400 }
        drain(c, "first configure")

        configure(c) { $0.sessionTimeout = 1 } // a 1-second inactivity window
        drain(c, "reconfigured")
        clock.date = clock.date.addingTimeInterval(5)
        c.track("after_the_gap", properties: [:])
        c.flush()
        drain(c, "tracked")

        let bodies = MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
        let sessionStarts = bodies.components(separatedBy: "\"_bcs.session_started\"").count - 1
        XCTAssertGreaterThanOrEqual(sessionStarts, 2,
                                    "the new sessionTimeout was silently ignored")
    }

    // MARK: - the URLSession is released

    func testReconfigureInvalidatesThePreviousURLSession() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        var witnesses: [InvalidationWitness] = []
        let c = BeaconstatCore(store: InMemorySecureStore(), clock: SystemClock(),
                               sessionProvider: { _ in
                                   let witness = InvalidationWitness()
                                   witnesses.append(witness)
                                   let config = URLSessionConfiguration.ephemeral
                                   config.protocolClasses = [MockURLProtocol.self]
                                   return URLSession(configuration: config, delegate: witness,
                                                     delegateQueue: nil)
                               },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: file, reachabilityFactory: { _ in nil })
        configure(c)
        drain(c, "first configure")
        configure(c)
        drain(c, "reconfigured")

        XCTAssertEqual(witnesses.count, 2)
        wait(for: [witnesses[0].invalidated], timeout: 3) // the first session must be released
        c.shutdown()
        wait(for: [witnesses[1].invalidated], timeout: 3) // shutdown releases the current one
    }

    // MARK: - shutdown()

    func testShutdownStopsTimersMonitorsAndObservers() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let reachability = ManualReachability()
        let observer = LifecycleObserver()
        let c = BeaconstatCore(store: InMemorySecureStore(), clock: SystemClock(),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: file, reachabilityFactory: { _ in reachability },
                               lifecycleObserver: observer)
        configure(c)
        drain(c, "configured")
        XCTAssertTrue(observer.isObserving)

        c.shutdown()
        drain(c, "shut down")
        XCTAssertEqual(reachability.stopCount, 1)
        XCTAssertFalse(observer.isObserving)
    }

    func testTrackAfterShutdownIsInert() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = BeaconstatCore(store: InMemorySecureStore(), clock: SystemClock(),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: file, reachabilityFactory: { _ in nil })
        configure(c)
        drain(c, "configured")
        c.shutdown()
        drain(c, "shut down")
        MockURLProtocol.reset()
        handshake202()
        c.track("after_shutdown", properties: [:])
        c.flush()
        drain(c, "after shutdown")
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
    }

    /// `shutdown()` must not be a one-way door — configuring again brings the
    /// SDK back, which is what makes it usable from an integration test.
    func testConfigureAfterShutdownWorksAgain() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = BeaconstatCore(store: InMemorySecureStore(), clock: SystemClock(),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: file, reachabilityFactory: { _ in nil })
        configure(c)
        drain(c, "configured")
        c.shutdown()
        drain(c, "shut down")
        MockURLProtocol.reset()
        handshake202()
        configure(c)
        c.track("after_reconfigure", properties: [:])
        c.flush()
        drain(c, "reconfigured")
        let bodies = MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
        XCTAssertTrue(bodies.contains("after_reconfigure"), bodies)
    }

    func testShutdownIsIdempotent() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = BeaconstatCore(store: InMemorySecureStore(), clock: SystemClock(),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: file, reachabilityFactory: { _ in nil })
        configure(c)
        drain(c, "configured")
        c.shutdown(); c.shutdown(); c.shutdown()
        drain(c, "shut down")
    }

    func testShutdownBeforeConfigureIsSafe() {
        let c = BeaconstatCore(store: InMemorySecureStore(), clock: SystemClock(),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: tempQueue(), reachabilityFactory: { _ in nil })
        c.shutdown()
        drain(c, "shut down")
    }
}

/// A `Clock` a test steps by hand.
final class SteppableClock: Clock {
    var date: Date
    init(_ d: Date) { date = d }
    func now() -> Date { date }
    func nowISO8601() -> String { iso8601(date) }
    func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
    func applyServerTime(_ iso: String) {}
}
