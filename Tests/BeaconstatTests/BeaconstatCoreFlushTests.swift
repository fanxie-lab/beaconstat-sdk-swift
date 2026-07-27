import XCTest
@testable import Beaconstat

final class BeaconstatCoreFlushTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func configuredCore(store: SecureStore = InMemorySecureStore(),
                                queueFile: URL) -> BeaconstatCore {
        let core = BeaconstatCore(store: store,
                                  clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                                  sessionProvider: { _ in .mocked() },
                                  bundleIdentifier: "com.example.app",
                                  queueFileURL: queueFile)
        var opts = BeaconstatOptions(); opts.flushInterval = 3600 // disable timer noise in test
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: opts, environment: ["device.platform": "ios"])
        return core
    }

    func testInstallEventFlushesViaQueueOn202() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202, data: Data(#"{"success":true,"eventsQueued":1}"#.utf8))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = configuredCore(queueFile: file)
        let done = expectation(description: "flow"); core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        // 202 → queue drained → persisted queue is empty.
        XCTAssertEqual(FileEventStore(fileURL: file).load(), [])
    }

    func testEventsKeptOnServerError() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 503) // server error on the events send
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = configuredCore(queueFile: file)
        let done = expectation(description: "flow"); core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        // 5xx → events retained for retry. As of M5, a session starts right
        // after handshake succeeds, before install_detected — both are
        // queued and neither has been acked yet.
        XCTAssertEqual(FileEventStore(fileURL: file).load().map(\.name),
                       ["_bcs.session_started", "_bcs.install_detected"])
    }

    func testPoisonBatchDroppedOn400() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 400)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = configuredCore(queueFile: file)
        let done = expectation(description: "flow"); core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(FileEventStore(fileURL: file).load(), []) // dropped, not retried forever
    }
}
