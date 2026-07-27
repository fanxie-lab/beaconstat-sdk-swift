import XCTest
@testable import Beaconstat

/// L2 — `flushInternal` encoded the body *after* `dequeueBatch`, so an encode
/// failure hit a `return` with the batch already deleted from disk and held
/// only by a local. The batch was silently destroyed.
///
/// Unreachable in practice with `[String: String]`, but the ordering was wrong,
/// and H6 added a field to that payload.
final class EncodeBeforeCheckoutTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private struct EncodingRefused: Error {}

    private func makeCore(file: URL, encoder: @escaping BatchEncoder) -> BeaconstatCore {
        BeaconstatCore(
            store: InMemorySecureStore(),
            clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
            sessionProvider: { _ in .mocked() },
            bundleIdentifier: "com.example.app", queueFileURL: file,
            reachabilityFactory: { _ in nil },
            payloadEncoder: encoder)
    }

    private func configure(_ core: BeaconstatCore) {
        var options = BeaconstatOptions()
        // Explicit rather than inherited from the build configuration — see
        // ConfigurationClampTests. Under Release the logger is off by default,
        // so a log assertion would pass vacuously.
        options.debugLogging = true
        options.flushInterval = 3600
        options.maxRetries = 0
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: ["device.platform": "ios"])
    }

    private func settle(_ core: BeaconstatCore) {
        let done = expectation(description: "quiescent")
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testAnEncodeFailureLosesNothing() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200,
                        data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = makeCore(file: file, encoder: { _, _ in throw EncodingRefused() })
        configure(core)
        settle(core)

        let onDisk = FileEventStore(fileURL: file).load().map(\.name)
        XCTAssertTrue(onDisk.contains("_bcs.session_started"), "\(onDisk)")
        XCTAssertTrue(onDisk.contains("_bcs.install_detected"), "\(onDisk)")
        core.shutdown()
    }

    /// Nothing may be checked out either, or the batch would be stranded
    /// in-flight with no completion coming to release it.
    func testAnEncodeFailureSendsNothingAndLeavesNothingInFlight() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200,
                        data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = makeCore(file: file, encoder: { _, _ in throw EncodingRefused() })
        configure(core)
        settle(core)

        XCTAssertTrue(MockURLProtocol.capturedRequests.allSatisfy { !$0.url!.path.hasSuffix("/events") },
                      "an unencodable batch must not be transmitted")

        // The events are still selectable: an encoder that works now drains them.
        let recovered = makeCore(file: file, encoder: { batch, ids in
            try PayloadEncoder.encode(batch, includeEventIds: ids)
        })
        configure(recovered)
        settle(recovered)
        XCTAssertEqual(FileEventStore(fileURL: file).load(), [],
                       "the batch was never stranded — a working encoder drains it")
        recovered.shutdown()
        core.shutdown()
    }

    func testAnEncodeFailureIsLogged() {
        let collector = LogCollector()
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200,
                        data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = BeaconstatCore(
            store: InMemorySecureStore(),
            clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
            sessionProvider: { _ in .mocked() },
            bundleIdentifier: "com.example.app", queueFileURL: file,
            reachabilityFactory: { _ in nil },
            payloadEncoder: { _, _ in throw EncodingRefused() },
            logSink: collector.append)
        configure(core)
        settle(core)
        XCTAssertTrue(collector.contains("leaving it queued"), "\(collector.lines)")
        core.shutdown()
    }
}
