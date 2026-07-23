import XCTest
@testable import Beaconstat

final class BeaconstatCoreCheckoutTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func core(file: URL) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app", sdkVersion: "9.9.9", queueFileURL: file)
    }

    // 5xx must re-prepend the checked-out batch (no loss) — the whole point of the model.
    func testServerErrorRequeuesCheckedOutBatch() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 503)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o, environment: ["device.platform": "ios"])
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        // Events survived the failed send (re-prepended to disk).
        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty)
    }

    // After a 5xx that requeues, a success on the next attempt drains the queue.
    func testDrainsRemainingAfterSuccess() {
        var calls = 0
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("/handshake") {
                return .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
            }
            calls += 1
            return .init(statusCode: 202) // events endpoint always succeeds
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600; o.batchSize = 1
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o, environment: ["device.platform": "ios"])
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty) // fully drained
    }
}
