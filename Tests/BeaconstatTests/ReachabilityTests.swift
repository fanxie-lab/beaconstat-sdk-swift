import XCTest
@testable import Beaconstat

final class ReachabilityTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // A test double we can trigger by hand.
    final class FakeReachability: Reachability {
        var onReconnect: (() -> Void)?
        private(set) var started = false
        func start() { started = true }
        func stop() {}
        func triggerReconnect() { onReconnect?() }
    }

    func testReconnectTriggersFlush() {
        // Handshake OK; the first events send FAILS (503) so the batch requeues;
        // then a reconnect fires and the retry send SUCCEEDS (202) -> queue drains.
        var eventCalls = 0
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("/handshake") {
                return .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
            }
            eventCalls += 1
            return eventCalls == 1 ? .init(statusCode: 503) : .init(statusCode: 202)
        }
        let fake = FakeReachability()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = BeaconstatCore(store: InMemorySecureStore(),
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app",
                               queueFileURL: file,
                               reachabilityFactory: { _ in fake })
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac, options: o, environment: ["device.platform": "ios"])
        let first = expectation(description: "first"); c.onQuiescent { first.fulfill() }
        wait(for: [first], timeout: 3)
        XCTAssertTrue(fake.started)
        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty) // requeued after 503

        fake.triggerReconnect()
        let second = expectation(description: "second"); c.onQuiescent { second.fulfill() }
        wait(for: [second], timeout: 3)
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty) // drained after reconnect
    }
}
