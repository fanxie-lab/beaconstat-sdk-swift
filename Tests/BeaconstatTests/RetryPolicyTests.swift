import XCTest
@testable import Beaconstat

final class RetryPolicyTests: XCTestCase {
    /// Deterministic stand-in for `Double.random(in:)`: always the top of the
    /// range, so the jittered schedule has an exact expected value.
    private let alwaysMax: (ClosedRange<TimeInterval>) -> TimeInterval = { $0.upperBound }
    private let alwaysMin: (ClosedRange<TimeInterval>) -> TimeInterval = { $0.lowerBound }

    private func delay(_ attempt: Int, maxRetries: Int = 3, retryAfter: TimeInterval? = nil,
                       randomizer: @escaping (ClosedRange<TimeInterval>) -> TimeInterval) -> TimeInterval? {
        RetryPolicy.delay(forAttempt: attempt, maxRetries: maxRetries,
                          retryAfter: retryAfter, randomizer: randomizer)
    }

    // MARK: - Jitter (M9)

    /// The schedule used to be a pure `min(pow(2, attempt), 30)` — a fixed
    /// 2s/4s/8s identical on every install in the world, so a server recovering
    /// from an outage got a synchronised thundering herd exactly 2s later.
    func testBackoffIsJitteredNotFixed() {
        // Equal jitter: half the backoff plus a random half.
        XCTAssertEqual(delay(1, randomizer: alwaysMin)!, 1, accuracy: 0.001)
        XCTAssertEqual(delay(1, randomizer: alwaysMax)!, 2, accuracy: 0.001)
        XCTAssertEqual(delay(2, randomizer: alwaysMin)!, 2, accuracy: 0.001)
        XCTAssertEqual(delay(2, randomizer: alwaysMax)!, 4, accuracy: 0.001)
        XCTAssertEqual(delay(3, randomizer: alwaysMin)!, 4, accuracy: 0.001)
        XCTAssertEqual(delay(3, randomizer: alwaysMax)!, 8, accuracy: 0.001)
    }

    /// Growth is preserved — the point of jitter is to spread the herd, not to
    /// abandon exponential backoff.
    func testJitteredDelaysStillGrowAndStayWithinTheCap() {
        for attempt in 1...10 {
            let value = RetryPolicy.delay(forAttempt: attempt, maxRetries: 10)!
            XCTAssertGreaterThan(value, 0, "a near-zero retry would hammer a recovering server")
            XCTAssertLessThanOrEqual(value, 30, "cap still applies")
        }
    }

    /// Two installs retrying at the same instant must not pick the same delay.
    func testRealRandomizerProducesASpread() {
        let samples = (0..<200).map { _ in RetryPolicy.delay(forAttempt: 3, maxRetries: 5)! }
        XCTAssertGreaterThan(Set(samples).count, 100, "the delays must actually differ")
        XCTAssertGreaterThanOrEqual(samples.min()!, 4)
        XCTAssertLessThanOrEqual(samples.max()!, 8)
    }

    func testBounds() {
        XCTAssertNil(RetryPolicy.delay(forAttempt: 4, maxRetries: 3))
        XCTAssertNil(RetryPolicy.delay(forAttempt: 0, maxRetries: 3))
        XCTAssertNil(RetryPolicy.delay(forAttempt: 1, maxRetries: 0))
    }

    // MARK: - Retry-After (M9)

    func testRetryAfterOverridesTheBackoffSchedule() {
        // 60s + up to 20% jitter, and the 20% is itself capped.
        XCTAssertEqual(delay(1, retryAfter: 60, randomizer: alwaysMin)!, 60, accuracy: 0.001)
        XCTAssertEqual(delay(1, retryAfter: 60, randomizer: alwaysMax)!, 70, accuracy: 0.001)
    }

    /// Even a server-set delay needs spreading: a fleet all told "60" would
    /// otherwise come back in one spike.
    func testRetryAfterIsStillJittered() {
        let samples = (0..<100).map {
            _ in RetryPolicy.delay(forAttempt: 1, maxRetries: 3, retryAfter: 30)!
        }
        XCTAssertGreaterThan(Set(samples).count, 50)
        XCTAssertGreaterThanOrEqual(samples.min()!, 30)
    }

    /// A broken or hostile `Retry-After: 999999` must not park the SDK for
    /// eleven days.
    func testAbsurdRetryAfterIsClamped() {
        let value = delay(1, retryAfter: 999_999, randomizer: alwaysMin)!
        XCTAssertEqual(value, RetryPolicy.maxRetryAfter, accuracy: 0.001)
    }

    func testNonPositiveRetryAfterFallsBackToTheSchedule() {
        XCTAssertEqual(delay(1, retryAfter: 0, randomizer: alwaysMax)!, 2, accuracy: 0.001)
        XCTAssertEqual(delay(1, retryAfter: -5, randomizer: alwaysMax)!, 2, accuracy: 0.001)
    }

    /// Retry-After applies even on the last permitted attempt, but not past it.
    func testRetryAfterStillRespectsTheAttemptBudget() {
        XCTAssertNotNil(delay(3, maxRetries: 3, retryAfter: 10, randomizer: alwaysMin))
        XCTAssertNil(delay(4, maxRetries: 3, retryAfter: 10, randomizer: alwaysMin))
    }

    // MARK: - Header parsing

    func testParsesDeltaSeconds() {
        XCTAssertEqual(RetryAfter.parse("120", now: Date()), 120)
        XCTAssertEqual(RetryAfter.parse("  45  ", now: Date()), 45)
        XCTAssertEqual(RetryAfter.parse("0", now: Date()), 0)
    }

    func testParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_445_412_400) // 2015-10-21T07:26:40Z
        let value = RetryAfter.parse("Wed, 21 Oct 2015 07:28:00 GMT", now: now)
        XCTAssertEqual(value ?? -1, 80, accuracy: 1)
    }

    /// A date already in the past means "now", not a negative delay.
    func testPastHTTPDateClampsToZero() {
        let now = Date(timeIntervalSince1970: 1_445_500_000)
        XCTAssertEqual(RetryAfter.parse("Wed, 21 Oct 2015 07:28:00 GMT", now: now), 0)
    }

    func testRejectsGarbageAndAbsence() {
        XCTAssertNil(RetryAfter.parse(nil, now: Date()))
        XCTAssertNil(RetryAfter.parse("", now: Date()))
        XCTAssertNil(RetryAfter.parse("soon", now: Date()))
        XCTAssertNil(RetryAfter.parse("NaN", now: Date()))
    }

    // MARK: - The tail (M9)

    /// After the last retry the code reset and deferred to the periodic timer —
    /// which in Release is 14,400 s. A queue could sit for four hours after
    /// fourteen seconds of trying, with the cap evicting underneath it.
    func testExhaustedRoundDelayIsMinutesNotHours() {
        XCTAssertLessThanOrEqual(RetryPolicy.exhaustedRoundDelay, 600)
        XCTAssertLessThan(RetryPolicy.exhaustedRoundDelay,
                          BeaconstatOptions.Limits.flushInterval.upperBound)
    }

    func testExhaustedRoundDelayIsJitteredAndBounded() {
        let samples = (0..<100).map { _ in RetryPolicy.exhaustedRoundDelay(cappedBy: 3600) }
        XCTAssertGreaterThan(Set(samples).count, 50, "a whole fleet must not come back together")
        XCTAssertGreaterThanOrEqual(samples.min()!, RetryPolicy.exhaustedRoundDelay / 2)
        XCTAssertLessThanOrEqual(samples.max()!, RetryPolicy.exhaustedRoundDelay)
    }

    /// A host that asked for a *shorter* flush interval than the recovery delay
    /// should not be made to wait longer than it asked for.
    func testAShorterFlushIntervalWins() {
        XCTAssertLessThanOrEqual(RetryPolicy.exhaustedRoundDelay(cappedBy: 20), 20)
    }
}

/// M9 — `Transport` discarded `allHeaderFields` entirely, so a 429's
/// `Retry-After` never reached the retry scheduler.
final class RetryAfterTransportTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func transport(now: @escaping () -> Date = Date.init) -> Transport {
        Transport(session: .mocked(), baseURL: URL(string: "https://ingest.beaconstat.com")!,
                  logger: Logger(enabled: false, sink: { _ in }), now: now)
    }

    private func send(_ transport: Transport) -> TransportError? {
        var captured: TransportError?
        let exp = expectation(description: "send")
        transport.sendBatch(bodyData: Data(), apiKey: "k", siteToken: "t", signature: "s",
                            timestamp: "ts", isTest: false, idempotencyKey: "i") { result in
            if case .failure(let error) = result { captured = error }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        return captured
    }

    func test429CarriesRetryAfterSeconds() {
        MockURLProtocol.handler = { _ in .init(statusCode: 429, headers: ["Retry-After": "90"]) }
        XCTAssertEqual(send(transport())?.retryAfter, 90)
    }

    /// 503 during a planned outage commonly carries it too.
    func test503CarriesRetryAfter() {
        MockURLProtocol.handler = { _ in .init(statusCode: 503, headers: ["Retry-After": "12"]) }
        XCTAssertEqual(send(transport())?.retryAfter, 12)
    }

    func testRetryAfterAsAnHTTPDateIsResolvedAgainstNow() {
        let now = Date(timeIntervalSince1970: 1_445_412_400) // 2015-10-21T07:26:40Z
        MockURLProtocol.handler = { _ in
            .init(statusCode: 429, headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"])
        }
        XCTAssertEqual(send(transport(now: { now }))?.retryAfter ?? -1, 80, accuracy: 1)
    }

    func testAbsentHeaderLeavesItNil() {
        MockURLProtocol.handler = { _ in .init(statusCode: 429) }
        XCTAssertNil(send(transport())?.retryAfter)
    }

    /// Statuses that are not backoff-shaped carry nothing, so nothing can
    /// accidentally delay a poison drop.
    func testNonBackoffStatusesCarryNoRetryAfter() {
        for status in [400, 403, 413, 401] {
            MockURLProtocol.reset()
            MockURLProtocol.handler = { _ in .init(statusCode: status, headers: ["Retry-After": "60"]) }
            XCTAssertNil(send(transport())?.retryAfter, "status \(status)")
        }
    }
}
