import XCTest
@testable import Beaconstat

/// Test gap 4 — status-code coverage **in the core**, not just in `Transport`.
///
/// `HeadOfLineBlockingTests` (Wave 2) closed most of this: it classifies every
/// interesting status at the transport level and drives 403 and 413 end to end
/// through the core. Two holes were left, and they are the two with the worst
/// failure mode:
///
/// - **401 on the send path.** Only the *handshake* 401 was tested
///   (`BeaconstatCoreHandshakeRecoveryTests.testUnauthorizedHandshakeHalts…`).
///   Nothing covered a 401 from `/v1/events`, which sets `stoppedForAuth` and
///   halts **all** delivery — the single most damaging state the SDK can enter —
///   nor that `configure()` clears it. A regression that failed to clear it
///   would leave a host permanently dark after one key rotation, and no test
///   would notice.
/// - **429 through the core.** Rate limiting is the status a busy deployment
///   actually returns, and it must requeue rather than drop.
final class DeliveryStatusCodeTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let handshakeBody =
        Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)

    /// Answers `handshakeStatus` to `/handshake` and `eventsStatus` to
    /// `/events`, so the two paths can be driven independently.
    private func stub(handshake: Int = 200, events: @escaping @Sendable () -> Int) {
        let body = handshakeBody
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("/handshake") {
                return .init(statusCode: handshake, data: handshake == 200 ? body : Data())
            }
            return .init(statusCode: events())
        }
    }

    private func core(file: URL, log: LogCollector? = nil) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app",
                       queueFileURL: file,
                       reachabilityFactory: { _ in nil },
                       logSink: log.map { collector in { collector.append($0) } })
    }

    private func configure(_ c: BeaconstatCore, maxRetries: Int = 0) {
        var o = BeaconstatOptions()
        o.flushInterval = 3600
        o.maxRetries = maxRetries
        o.debugLogging = true
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow") {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func eventsRequestCount() -> Int {
        MockURLProtocol.requests(forPathSuffix: "/events").count
    }

    // MARK: - 401 on the send path

    /// A 401 from ingest must requeue the batch (it is not the batch's fault)
    /// and stop sending entirely. Retrying a rejected key is pointless and
    /// hammers the server.
    func testUnauthorizedSendHaltsDeliveryAndKeepsTheEvents() {
        stub(events: { 401 })
        let file = makeTemporaryQueueFile()
        let log = LogCollector()
        let c = core(file: file, log: log)
        configure(c)
        drain(c, "launch")

        let afterHalt = eventsRequestCount()
        XCTAssertGreaterThan(afterHalt, 0, "nothing was ever sent, so nothing was halted")

        // Every subsequent trigger must be inert.
        for i in 0..<5 {
            c.track("feature_used", properties: ["i": "\(i)"])
            c.flush()
        }
        drain(c, "after halt")
        XCTAssertEqual(eventsRequestCount(), afterHalt,
                       "kept sending after a 401 — a rejected key must stop delivery")
        XCTAssertTrue(log.contains("unauthorized"), "\(log.lines)")

        // The events are still on disk. A 401 is a credential problem, not a
        // data problem: dropping them would lose real analytics over a
        // fixable configuration mistake.
        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty,
                       "a 401 discarded the batch instead of requeueing it")
        c.shutdown()
    }

    /// ...and `configure()` must clear the halt. This is the recovery path the
    /// review called out by name, and it had no test: a host that rotates its
    /// key and reconfigures has to start sending again, and everything queued
    /// during the halt has to go out.
    func testReconfigureClearsTheAuthHaltAndDrainsWhatQueuedDuringIt() {
        let rejecting = Locked(true)
        stub(events: { rejecting.value ? 401 : 202 })
        let file = makeTemporaryQueueFile()
        let c = core(file: file)
        configure(c)
        drain(c, "launch")
        let duringHalt = eventsRequestCount()

        c.track("queued_while_halted", properties: [:])
        c.flush()
        drain(c, "halted")
        XCTAssertEqual(eventsRequestCount(), duringHalt, "not actually halted")

        // The host notices, rotates the key, reconfigures.
        rejecting.value = false
        configure(c)
        drain(c, "reconfigured")

        XCTAssertGreaterThan(eventsRequestCount(), duringHalt,
                            "reconfigure did not clear stoppedForAuth")
        XCTAssertTrue(MockURLProtocol.eventBodies().contains("queued_while_halted"),
                      "events queued during the halt were never delivered")
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty, "queue not drained")
        c.shutdown()
    }

    /// `shutdown()` + `configure()` must recover too — the other way a host can
    /// reset the SDK.
    func testShutdownThenConfigureAlsoClearsTheAuthHalt() {
        let rejecting = Locked(true)
        stub(events: { rejecting.value ? 401 : 202 })
        let file = makeTemporaryQueueFile()
        let c = core(file: file)
        configure(c)
        drain(c, "launch")
        let duringHalt = eventsRequestCount()

        c.shutdown()
        drain(c, "shut down")
        rejecting.value = false
        configure(c)
        c.track("after_restart", properties: [:])
        c.flush()
        drain(c, "restarted")

        XCTAssertGreaterThan(eventsRequestCount(), duringHalt)
        XCTAssertTrue(MockURLProtocol.eventBodies().contains("after_restart"))
        c.shutdown()
    }

    // MARK: - 429

    /// Rate limiting must requeue, never drop — and must not halt the way 401
    /// does. The distinction matters: 429 is temporary and 401 is not.
    func testRateLimitedSendRequeuesTheBatchAndKeepsTrying() {
        let limited = Locked(true)
        stub(events: { limited.value ? 429 : 202 })
        let file = makeTemporaryQueueFile()
        let c = core(file: file)
        configure(c)
        drain(c, "rate limited")

        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty,
                       "a 429 dropped the batch — it must be retried")

        limited.value = false
        c.flush()
        drain(c, "recovered")
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty,
                      "the queue did not drain once the limit lifted")
        XCTAssertTrue(MockURLProtocol.eventBodies().contains("_bcs.install_detected"))
        c.shutdown()
    }

    /// A `Retry-After` on a 429 must be honoured over the local schedule (M9).
    /// Asserted at the transport boundary, because waiting out a real delay in a
    /// unit test is exactly the flake this suite avoids.
    func testRetryAfterOnA429IsParsedAndCarried() {
        MockURLProtocol.handler = { _ in .init(statusCode: 429, headers: ["Retry-After": "120"]) }
        let transport = Transport(session: .mocked(),
                                  baseURL: URL(string: "https://ingest.beaconstat.com")!,
                                  logger: Logger(enabled: false, sink: { _ in }))
        var captured: Result<Void, TransportError>?
        let done = expectation(description: "429")
        transport.sendBatch(bodyData: Data("{}".utf8), apiKey: "k", siteToken: "t", signature: "s",
                            timestamp: "ts", isTest: false, idempotencyKey: "i") {
            captured = $0; done.fulfill()
        }
        wait(for: [done], timeout: 3)
        guard case .failure(let error)? = captured else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, .rateLimited(retryAfter: 120))
        XCTAssertEqual(error.retryAfter, 120)
    }

    // MARK: - 200-but-not-202

    /// A captive portal answering 200 with an HTML login page used to be
    /// `.unexpected(200)` and retried forever. Driven through the core here, not
    /// just classified: the queue must drain.
    func testCaptivePortalStyle200DrainsTheQueueInsteadOfLooping() {
        stub(events: { 200 })
        let file = makeTemporaryQueueFile()
        let log = LogCollector()
        let c = core(file: file, log: log)
        configure(c)
        drain(c, "launch")
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty,
                      "a non-202 2xx wedged the queue")
        XCTAssertTrue(log.contains("instead of 202"), "\(log.lines)")
        c.shutdown()
    }

    /// 500 must requeue and stay retryable — the counterpart to the poison-drop
    /// cases, so a server outage never costs data.
    func testServerErrorRequeuesAndRecovers() {
        let failing = Locked(true)
        stub(events: { failing.value ? 503 : 202 })
        let file = makeTemporaryQueueFile()
        let c = core(file: file)
        configure(c)
        drain(c, "outage")
        XCTAssertFalse(FileEventStore(fileURL: file).load().isEmpty)

        failing.value = false
        c.flush()
        drain(c, "recovered")
        XCTAssertTrue(FileEventStore(fileURL: file).load().isEmpty)
        c.shutdown()
    }
}

/// A `Sendable` box for a value a test flips while the SDK is running.
///
/// Tests used to capture a bare `var` into the mock's handler, which is invoked
/// from a URLSession loading thread — an unsynchronised cross-thread write.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
