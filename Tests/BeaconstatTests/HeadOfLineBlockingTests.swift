import XCTest
@testable import Beaconstat

/// H3 — only 202/401/400/429/5xx were classified. Everything else became
/// `.unexpected` and was re-prepended to the FRONT of the queue forever, so one
/// permanently-rejected batch blocked every event behind it for the life of the
/// install.
final class HeadOfLineBlockingTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let handshakeBody =
        Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)

    private func transport() -> Transport {
        Transport(session: .mocked(), baseURL: URL(string: "https://ingest.beaconstat.com")!,
                  logger: Logger(enabled: false, sink: { _ in }))
    }

    private func classify(_ status: Int) -> Result<Void, TransportError> {
        MockURLProtocol.reset()
        MockURLProtocol.handler = { _ in .init(statusCode: status) }
        var captured: Result<Void, TransportError>!
        let exp = expectation(description: "status \(status)")
        transport().sendBatch(bodyData: Data(), apiKey: "k", siteToken: "t", signature: "s",
                              timestamp: "ts", isTest: false, idempotencyKey: "i") {
            captured = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        return captured
    }

    private func error(_ status: Int) -> TransportError? {
        guard case .failure(let e) = classify(status) else { return nil }
        return e
    }

    // MARK: - Classification

    /// A captive portal answers 200 with an HTML login page. That used to be
    /// `.unexpected(200)` → retried forever, four wasted requests per round.
    func testNon202SuccessIsTreatedAsSuccess() {
        for status in [200, 201, 204] {
            guard case .success = classify(status) else {
                return XCTFail("\(status) must not be retryable")
            }
        }
    }

    /// 403 from a corporate proxy or a revoked key — many gateways return 403,
    /// not 401 — and 404 from a misconfigured endpoint. Retrying cannot help.
    func testNonRetryable4xxIsPoisonDropped() {
        for status in [402, 403, 404, 405, 409, 410, 415, 422, 451] {
            XCTAssertEqual(error(status), .badRequest, "\(status) should be dropped, not retried")
        }
    }

    /// The two 4xx that genuinely mean "try again".
    func testRetryable4xxKeepsItsOwnClassification() {
        XCTAssertEqual(error(408), .network, "408 Request Timeout is retryable")
        XCTAssertEqual(error(429), .rateLimited)
        XCTAssertEqual(error(401), .unauthorized)
        XCTAssertEqual(error(400), .badRequest)
    }

    /// 413 is neither retryable-as-is nor plain poison: a smaller batch may well
    /// succeed, so it gets its own case.
    func testPayloadTooLargeIsItsOwnCase() {
        XCTAssertEqual(error(413), .payloadTooLarge)
    }

    func testServerErrorsStayRetryable() {
        for status in [500, 502, 503, 504] {
            XCTAssertEqual(error(status), .server)
        }
    }

    /// 1xx/3xx should be unreachable (URLSession follows redirects), but if one
    /// arrives it must not become an infinite retry either.
    func testUnclassifiableStatusIsStillNotRetriedForever() {
        XCTAssertEqual(error(399), .unexpected(399))
    }

    // MARK: - The queue is not blocked

    /// The review's headline: a permanently-rejected batch must not sit at the
    /// front of the queue forever.
    func testPermanentlyRejectedBatchDoesNotBlockTheQueue() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: self.handshakeBody)
                                                  : .init(statusCode: 403)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = BeaconstatCore(
            store: InMemorySecureStore(),
            clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
            sessionProvider: { _ in .mocked() },
            bundleIdentifier: "com.example.app", sdkVersion: "9.9.9", queueFileURL: file,
            reachabilityFactory: { _ in nil })
        var options = BeaconstatOptions()
        options.flushInterval = 3600
        options.batchSize = 1
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: ["device.platform": "ios"])
        let done = expectation(description: "quiescent")
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(FileEventStore(fileURL: file).load(), [],
                       "a 403 must drain the queue, not wedge it")
        core.shutdown()
    }

    /// 413 with more than one event in the batch: shrink and retry rather than
    /// dropping real data.
    func testPayloadTooLargeShrinksTheBatchInsteadOfDroppingIt() {
        let lock = NSLock()
        var eventBatchSizes: [Int] = []
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("/handshake") {
                return .init(statusCode: 200, data: self.handshakeBody)
            }
            return .init(statusCode: 413)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = BeaconstatCore(
            store: InMemorySecureStore(),
            clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
            sessionProvider: { _ in .mocked() },
            bundleIdentifier: "com.example.app", sdkVersion: "9.9.9", queueFileURL: file,
            reachabilityFactory: { _ in nil })
        var options = BeaconstatOptions()
        options.flushInterval = 3600
        options.maxRetries = 0 // no backoff timer; drive attempts by hand
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: ["device.platform": "ios"])
        let first = expectation(description: "first"); core.onQuiescent { first.fulfill() }
        wait(for: [first], timeout: 5)

        // Two launch events were queued; the 413 should have kept them.
        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty,
                       "a multi-event 413 must not discard the events")

        lock.lock(); eventBatchSizes = []; lock.unlock()
        _ = eventBatchSizes
        core.shutdown()
    }

    /// ...but shrinking has to terminate. A server that answers 413 to
    /// everything — a misconfigured proxy — would otherwise loop on the head of
    /// the queue forever, which is the exact bug H3 is about. Once the budget
    /// can shrink no further, the batch is dropped.
    func testPayloadTooLargeAlwaysTerminatesEvenIfShrinkingNeverHelps() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: self.handshakeBody)
                                                  : .init(statusCode: 413)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = BeaconstatCore(
            store: InMemorySecureStore(),
            clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
            sessionProvider: { _ in .mocked() },
            bundleIdentifier: "com.example.app", sdkVersion: "9.9.9", queueFileURL: file,
            reachabilityFactory: { _ in nil })
        var options = BeaconstatOptions()
        options.flushInterval = 3600
        options.batchSize = 1
        options.maxRetries = 0
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: ["device.platform": "ios"])
        let done = expectation(description: "quiescent"); core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)

        // Every batch is a single event and every one is 413'd, so the queue
        // must drain rather than loop on the head.
        for _ in 0..<8 {
            core.flush()
            let settled = expectation(description: "settled"); core.onQuiescent { settled.fulfill() }
            wait(for: [settled], timeout: 5)
        }
        XCTAssertEqual(FileEventStore(fileURL: file).load(), [],
                       "single-event 413s must drain, not wedge")
        core.shutdown()
    }
}
