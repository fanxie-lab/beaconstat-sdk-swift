import XCTest
@testable import Beaconstat

final class BeaconstatCoreAppUpdatedTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func sentBodies() -> String {
        MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? String(data: MockURLProtocol.capturedBodies[i], encoding: .utf8) : nil
        }.joined()
    }

    private func run(store: SecureStore, env: [String: String]) {
        let c = BeaconstatCore(store: store,
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app",
                               queueFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json"))
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o, environment: env)
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    private func handshake202() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
    }

    func testNoAppUpdatedOnFirstInstall() {
        handshake202()
        run(store: InMemorySecureStore(), env: ["device.platform": "ios", "app.version": "1.0.0", "app.build": "1"])
        XCTAssertFalse(sentBodies().contains("_bcs.apple.app_updated"))
    }

    func testAppUpdatedWhenVersionChanged() {
        handshake202()
        let store = InMemorySecureStore()
        store.set("1", forKey: .hasEmittedInstall)      // existing install
        store.set("1.0.0", forKey: .lastKnownVersion)
        store.set("1", forKey: .lastKnownBuild)
        run(store: store, env: ["device.platform": "ios", "app.version": "1.1.0", "app.build": "5"])
        let body = sentBodies()
        XCTAssertTrue(body.contains("_bcs.apple.app_updated"))
        XCTAssertTrue(body.contains("_bcs.apple.previous_version"))
        XCTAssertTrue(body.contains("1.0.0"))
    }

    func testNoAppUpdatedWhenSameVersion() {
        handshake202()
        let store = InMemorySecureStore()
        store.set("1", forKey: .hasEmittedInstall)
        store.set("1.1.0", forKey: .lastKnownVersion)
        store.set("5", forKey: .lastKnownBuild)
        run(store: store, env: ["device.platform": "ios", "app.version": "1.1.0", "app.build": "5"])
        XCTAssertFalse(sentBodies().contains("_bcs.apple.app_updated"))
    }
}
