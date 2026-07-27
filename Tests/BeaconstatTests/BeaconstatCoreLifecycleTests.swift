import XCTest
@testable import Beaconstat

final class BeaconstatCoreLifecycleTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /// A `Clock` whose `date` can be advanced deterministically from a test,
    /// mirroring the one in `SessionManagerTests`. `applyServerTime` is a
    /// no-op so the handshake response's serverTime never perturbs the
    /// clock the test controls.
    private final class MutableClock: Clock {
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

    private func sentBodies() -> [String] {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }
    }

    private func configuredCore(file: URL, observer: LifecycleObserver) -> BeaconstatCore {
        let c = BeaconstatCore(store: InMemorySecureStore(),
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app",
                               queueFileURL: file, lifecycleObserver: observer)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o, environment: ["device.platform": "ios"])
        return c
    }

    func testBackgroundEmitsAppBackgroundedAndFlushes() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let observer = LifecycleObserver()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = configuredCore(file: file, observer: observer)
        let ready = expectation(description: "ready"); c.onQuiescent { ready.fulfill() }
        wait(for: [ready], timeout: 3)

        observer.onBackground?() // simulate the OS background notification
        let done = expectation(description: "bg"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let all = sentBodies().joined()
        XCTAssertTrue(all.contains("_bcs.apple.app_backgrounded"))
        XCTAssertTrue(all.contains("_bcs.session.id"))
    }

    func testForegroundAfterTimeoutResumesWithNewSessionStarted() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let observer = LifecycleObserver()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_776_594_600))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = BeaconstatCore(store: InMemorySecureStore(),
                              clock: clock,
                              sessionProvider: { _ in .mocked() },
                              bundleIdentifier: "com.example.app",
                              queueFileURL: file, lifecycleObserver: observer)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o,
                    environment: ["device.platform": "ios"])

        let ready = expectation(description: "ready"); c.onQuiescent { ready.fulfill() }
        wait(for: [ready], timeout: 3)
        let firstCount = sentBodies().joined().components(separatedBy: "\"_bcs.session_started\"").count - 1
        XCTAssertEqual(firstCount, 1) // initial session, started during configure/handshake

        clock.date = clock.date.addingTimeInterval(o.sessionTimeout + 1) // exceed the 300s default timeout
        observer.onForeground?() // simulate the OS foreground notification
        c.flush() // surface the resumed-session event over the wire deterministically
        let done = expectation(description: "fg"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)

        let secondCount = sentBodies().joined().components(separatedBy: "\"_bcs.session_started\"").count - 1
        XCTAssertEqual(secondCount, 2) // a second, brand-new session_started after the timeout
    }
}
