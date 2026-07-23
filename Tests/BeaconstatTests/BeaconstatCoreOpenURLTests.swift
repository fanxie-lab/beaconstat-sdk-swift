import XCTest
@testable import Beaconstat

final class BeaconstatCoreOpenURLTests: XCTestCase {
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

    func testUniversalLinkSanitizesPathAndQuery() {
        let c = makeCore()
        c.trackOpenURL(URL(string: "https://example.com/secret/path?token=abc123#frag")!)
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let body = sentBodies()
        XCTAssertTrue(body.contains("_bcs.apple.opened_from_url"))
        XCTAssertTrue(body.contains("universal_link"))
        XCTAssertTrue(body.contains("example.com"))
        XCTAssertFalse(body.contains("secret"))    // path never sent
        XCTAssertFalse(body.contains("token"))      // query never sent
        XCTAssertFalse(body.contains("abc123"))
        XCTAssertFalse(body.contains("frag"))
    }

    func testCustomSchemeIsUrlScheme() {
        let c = makeCore()
        c.trackOpenURL(URL(string: "myapp://open/item/42")!)
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let body = sentBodies()
        XCTAssertTrue(body.contains("url_scheme"))
        XCTAssertTrue(body.contains("myapp"))
        XCTAssertFalse(body.contains("42"))
    }

    func testOpenActivityWithNilURL() {
        let c = makeCore()
        c.trackOpenActivity(nil)
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let body = sentBodies()
        XCTAssertTrue(body.contains("_bcs.apple.opened_from_url"))
        XCTAssertTrue(body.contains("activity"))
        XCTAssertTrue(body.contains("_bcs.session.id"))
        XCTAssertFalse(body.contains("_bcs.apple.url_scheme"))
        XCTAssertFalse(body.contains("_bcs.apple.url_host"))
    }

    func testOpenActivityWithWebpageURL() {
        let c = makeCore()
        c.trackOpenActivity(URL(string: "https://example.com/deep/path?x=1"))
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let body = sentBodies()
        XCTAssertTrue(body.contains("activity"))          // entry_type — NOT universal_link, hardcoded
        XCTAssertFalse(body.contains("universal_link"))
        XCTAssertTrue(body.contains("example.com"))
        XCTAssertFalse(body.contains("deep"))               // path never sent
        XCTAssertFalse(body.contains("path"))
        XCTAssertFalse(body.contains("x=1"))                 // query never sent
    }

    func testSchemeComparisonIsCaseInsensitive() {
        let c = makeCore()
        c.trackOpenURL(URL(string: "HTTPS://Example.COM/foo")!)
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        let body = sentBodies()
        XCTAssertTrue(body.contains("universal_link")) // proves .lowercased() scheme check
        XCTAssertTrue(body.contains("example.com"))      // host lowercased
        XCTAssertFalse(body.contains("Example.COM"))
    }
}
