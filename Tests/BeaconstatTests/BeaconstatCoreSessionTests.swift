import XCTest
@testable import Beaconstat

final class BeaconstatCoreSessionTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // Collect every event JSON sent to the events endpoint.
    private func sentEventBodies() -> [String] {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }
    }

    private func core(file: URL) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app", sdkVersion: "9.9.9", queueFileURL: file)
    }

    func testSessionStartedAndInstallAreTaggedAndFirst() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var opts = BeaconstatOptions(); opts.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: opts, environment: ["device.platform": "ios"])
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let all = sentEventBodies().joined()
        XCTAssertTrue(all.contains("_bcs.session_started"))
        XCTAssertTrue(all.contains("_bcs.install_detected"))
        XCTAssertTrue(all.contains("_bcs.is_first_session"))
        XCTAssertTrue(all.contains("_bcs.session.id"))
    }

    func testTrackValidatesAndTagsUserEvents() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var opts = BeaconstatOptions(); opts.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: opts, environment: ["device.platform": "ios"])
        c.track("feature_used", properties: ["feature": "export"]) // valid
        c.track("_bcs.hack", properties: [:])                       // invalid: reserved prefix → dropped
        c.track("Bad Name", properties: [:])                        // invalid: regex → dropped
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let all = sentEventBodies().joined()
        XCTAssertTrue(all.contains("feature_used"))
        XCTAssertFalse(all.contains("_bcs.hack"))
        XCTAssertFalse(all.contains("Bad Name"))
        // The user event carries a session id.
        XCTAssertTrue(all.contains("_bcs.session.id"))
    }

    func testOptedOutSendsNothing() {
        MockURLProtocol.handler = { _ in .init(statusCode: 200) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = InMemorySecureStore(); store.set("1", forKey: .optedOut)
        let c = BeaconstatCore(store: store,
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9", queueFileURL: file)
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: BeaconstatOptions(), environment: [:])
        c.track("feature_used", properties: [:])
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty) // opt-out: no handshake, no events
    }
}
