import XCTest
@testable import Beaconstat

final class BeaconstatCoreHandshakeTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func makeCore(store: SecureStore) -> BeaconstatCore {
        BeaconstatCore(store: store,
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app",
                       sdkVersion: "9.9.9")
    }

    func testHandshakeThenSignedInstallEvent() {
        var seen: [String] = [] // request path order
        MockURLProtocol.handler = { req in
            seen.append(req.url!.path)
            if req.url!.path.hasSuffix("/handshake") {
                return .init(statusCode: 200,
                             data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:32:00.000Z"}"#.utf8))
            }
            return .init(statusCode: 202, data: Data(#"{"success":true,"eventsQueued":1}"#.utf8))
        }
        let store = InMemorySecureStore()
        let core = makeCore(store: store)
        let done = expectation(description: "flow")
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: BeaconstatOptions(), environment: ["device.platform": "ios"])
        core.onQuiescent { done.fulfill() } // test hook: fires when the serial queue drains
        wait(for: [done], timeout: 3)

        XCTAssertEqual(seen, ["/v1/handshake", "/v1/debug/events"]) // DEBUG build → test endpoint
        XCTAssertEqual(store.string(forKey: .siteToken), "bcs_tok_z")
        XCTAssertNotNil(store.string(forKey: .hasEmittedInstall))
        // The events request carried the required signed headers.
        let eventsReq = MockURLProtocol.capturedRequests.first { $0.url!.path.hasSuffix("/events") }!
        XCTAssertEqual(eventsReq.value(forHTTPHeaderField: "x-site-token"), "bcs_tok_z")
        XCTAssertNotNil(eventsReq.value(forHTTPHeaderField: "x-signature"))
        XCTAssertNotNil(eventsReq.value(forHTTPHeaderField: "x-timestamp"))
        // Body contains the install event.
        let body = String(data: MockURLProtocol.capturedBodies.first(where: { !$0.isEmpty && String(data: $0, encoding: .utf8)!.contains("install") })!, encoding: .utf8)!
        XCTAssertTrue(body.contains("_bcs.install_detected"))
    }

    func testInstallDetectedFiresOnlyOnce() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let store = InMemorySecureStore()
        store.set("1", forKey: .hasEmittedInstall) // already emitted before
        let core = makeCore(store: store)
        let done = expectation(description: "flow")
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: BeaconstatOptions(), environment: ["device.platform": "ios"])
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        // `install_detected` must not be re-emitted. A send does happen: since
        // C1 a successful handshake flushes what's already queued, which on this
        // path is the run's `session_started` — previously that sat on disk until
        // the periodic timer (4 hours away in Release).
        let sent = MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
        XCTAssertFalse(sent.contains("_bcs.install_detected"))
        XCTAssertTrue(sent.contains("_bcs.session_started"))
    }

    func testInvalidKeysDisableSilently() {
        MockURLProtocol.handler = { _ in .init(statusCode: 200) }
        let core = makeCore(store: InMemorySecureStore())
        let done = expectation(description: "flow")
        core.configure(publicKey: "not_valid", hmacSecret: "short",
                       options: BeaconstatOptions(), environment: [:])
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty) // never hit the network
    }
}
