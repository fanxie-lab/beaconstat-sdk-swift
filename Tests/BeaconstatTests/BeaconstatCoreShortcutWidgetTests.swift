import XCTest
@testable import Beaconstat

final class BeaconstatCoreShortcutWidgetTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func sentBodies() -> String {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
    }

    private func makeCore() -> BeaconstatCore {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let c = BeaconstatCore(store: InMemorySecureStore(),
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app", sdkVersion: "9.9.9",
                               queueFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json"))
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o, environment: ["device.platform": "ios"])
        return c
    }

    func testShortcut() {
        let c = makeCore()
        c.trackShortcut("com.example.newItem"); c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let body = sentBodies()
        XCTAssertTrue(body.contains("_bcs.apple.opened_from_shortcut"))
        XCTAssertTrue(body.contains("_bcs.apple.shortcut_type"))
        XCTAssertTrue(body.contains("_bcs.session.id"))
    }

    func testWidget() {
        let c = makeCore()
        c.trackWidget(kind: "TodayWidget", family: "systemSmall"); c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let body = sentBodies()
        XCTAssertTrue(body.contains("_bcs.apple.opened_from_widget"))
        XCTAssertTrue(body.contains("systemSmall"))
    }
}
