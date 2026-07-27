import XCTest
@testable import Beaconstat

/// M6 — the deferred half of the environment snapshot is collected on the
/// core's serial queue instead of on main at launch. The constraint the review
/// called out explicitly: this must not race with the
/// `configure()` → handshake ordering.
final class BeaconstatCoreDeferredEnvironmentTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func core(file: URL) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app",
                       queueFileURL: file, reachabilityFactory: { _ in nil })
    }

    private func handshake202() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
    }

    /// Both halves must be on the wire — a deferred key going missing would be a
    /// silent loss of a frozen wire dimension.
    func testDeferredKeysReachTheWireAlongsideTheEagerOnes() {
        handshake202()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o,
                    environment: ["device.screen_width": "390"],
                    deferredEnvironment: { ["device.model": "iPhone15,2", "locale": "en_GB"] })
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)

        let body = MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
        XCTAssertTrue(body.contains("device.screen_width"), body)
        XCTAssertTrue(body.contains("iPhone15,2"), body)
        XCTAssertTrue(body.contains("en_GB"), body)
    }

    /// The ordering constraint: the deferred collection must complete before the
    /// handshake leaves, because routing (`run_context.is_testflight`) and the
    /// first batch both read the merged snapshot.
    func testDeferredCollectionCompletesBeforeTheHandshakeIsSent() {
        let order = LogCollector()
        MockURLProtocol.handler = { req in
            order.append("request:\(req.url!.path)")
            return req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o,
                    environment: [:],
                    deferredEnvironment: {
                        order.append("deferred-collected")
                        return ["device.model": "iPhone15,2"]
                    })
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)

        let lines = order.lines
        guard let deferredIndex = lines.firstIndex(of: "deferred-collected"),
              let firstRequestIndex = lines.firstIndex(where: { $0.hasPrefix("request:") }) else {
            return XCTFail("expected both a deferred collection and a request: \(lines)")
        }
        XCTAssertLessThan(deferredIndex, firstRequestIndex,
                          "the handshake left before the environment was complete: \(lines)")
    }

    /// Eagerly collected main-thread keys win a collision, so a stale deferred
    /// value can never overwrite live UI state.
    func testEagerMainThreadKeysWinACollision() {
        handshake202()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o,
                    environment: ["user_preference.color_scheme": "dark"],
                    deferredEnvironment: { ["user_preference.color_scheme": "light"] })
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)

        let body = MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
        XCTAssertTrue(body.contains(#""user_preference.color_scheme":"dark""#), body)
    }

    /// Omitting the deferred closure must keep the old behaviour exactly — the
    /// whole existing suite relies on it.
    func testNoDeferredClosureIsSupported() {
        handshake202()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o,
                    environment: ["device.platform": "ios"])
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertFalse(MockURLProtocol.capturedRequests.isEmpty)
    }
}
