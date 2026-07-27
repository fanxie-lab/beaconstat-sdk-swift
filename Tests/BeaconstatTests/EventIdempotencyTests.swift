import XCTest
@testable import Beaconstat

/// H6 — a lost 202 (cellular handoff, or a timeout firing after the server
/// committed) made the client resend identical events with a fresh timestamp
/// and signature, and the server had nothing to dedupe on.
final class EventIdempotencyTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // MARK: - The id itself

    func testEveryEventGetsAUniqueId() {
        let a = Event(name: "x", time: "t")
        let b = Event(name: "x", time: "t")
        XCTAssertFalse(a.id.isEmpty)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotNil(UUID(uuidString: a.id), "should be a UUID the server can store as one")
    }

    /// The point of the whole exercise: the id must be a property of the event,
    /// not of the attempt. Regenerating it per send would defeat it entirely.
    func testIdIsStableAcrossPersistenceRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Event(name: "x", time: "t", properties: ["k": "v"])
        let store = FileEventStore(fileURL: url)
        store.save([original])
        let reloaded = FileEventStore(fileURL: url).load()
        XCTAssertEqual(reloaded.first?.id, original.id,
                       "an id that changes when the queue is reloaded cannot dedupe a retry")
    }

    /// A `queue.json` written by 1.0.0 has no `id`. It must still load — losing
    /// the whole queue on upgrade would be a worse bug than the one being fixed.
    func testLegacyQueueFileWithoutIdsStillLoads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"[{"name":"legacy","time":"t"}]"#.utf8).write(to: url)
        let loaded = FileEventStore(fileURL: url).load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "legacy")
        XCTAssertFalse(loaded.first?.id.isEmpty ?? true, "back-filled with a fresh id")
    }

    // MARK: - Wire format

    /// The API's global `ValidationPipe` uses `forbidNonWhitelisted: true`, and
    /// `EventDto` declares only name/time/properties. An unknown `id` would
    /// 400 the ENTIRE batch, not just the offending event. So it stays off the
    /// body until the server declares it.
    func testEventIdIsNotOnTheWireByDefault() throws {
        let batch = EventBatch(productVersion: "1.0.0", environment: [:],
                               events: [Event(name: "x", time: "t")])
        let json = String(data: try PayloadEncoder.encode(batch), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"id\""), "would be rejected by ingest today: \(json)")
    }

    func testEventIdIsOnTheWireWhenExplicitlyEnabled() throws {
        let event = Event(name: "x", time: "t")
        let batch = EventBatch(productVersion: "1.0.0", environment: [:], events: [event])
        let json = String(data: try PayloadEncoder.encode(batch, includeEventIds: true),
                          encoding: .utf8)!
        XCTAssertTrue(json.contains("\"id\":\"\(event.id)\""), json)
    }

    /// Persistence must ALWAYS carry the id, whatever the wire flag says —
    /// otherwise the id is lost at exactly the moment it is needed.
    func testPersistenceAlwaysCarriesTheIdRegardlessOfTheWireFlag() throws {
        let event = Event(name: "x", time: "t")
        let json = String(data: try JSONEncoder().encode([event]), encoding: .utf8)!
        XCTAssertTrue(json.contains(event.id), json)
    }

    // MARK: - Idempotency key

    func testIdempotencyKeyIsDerivedFromTheMemberIdsAndIsOrderSensitive() {
        let a = Event(name: "a", time: "t")
        let b = Event(name: "b", time: "t")
        XCTAssertEqual(IdempotencyKey.forBatch([a, b]), IdempotencyKey.forBatch([a, b]))
        XCTAssertNotEqual(IdempotencyKey.forBatch([a, b]), IdempotencyKey.forBatch([b, a]))
        XCTAssertNotEqual(IdempotencyKey.forBatch([a, b]), IdempotencyKey.forBatch([a]))
        XCTAssertEqual(IdempotencyKey.forBatch([a, b]).count, 64, "sha256 hex")
    }

    // MARK: - End to end

    /// The retry must carry the SAME idempotency key. A key derived from the
    /// attempt (a fresh UUID, a timestamp) would be indistinguishable from a
    /// genuinely new batch and dedupe nothing.
    func testRetryAfterAFailureReusesTheSameIdempotencyKey() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        let lock = NSLock()
        var eventAttempts = 0
        MockURLProtocol.handler = { req in
            if req.url!.path.hasSuffix("/handshake") { return .init(statusCode: 200, data: handshake) }
            lock.lock(); eventAttempts += 1; let n = eventAttempts; lock.unlock()
            return .init(statusCode: n == 1 ? 503 : 202) // first send fails, second succeeds
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
        options.maxRetries = 3
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: ["device.platform": "ios"])
        let failed = expectation(description: "first attempt failed")
        core.onQuiescent { failed.fulfill() }
        wait(for: [failed], timeout: 5)

        // Drive the second attempt explicitly rather than waiting on the
        // backoff timer — `flush()` is the same `flushInternal` path the retry
        // timer, the periodic timer and reconnect all use, and it keeps the
        // test off the wall clock.
        core.flush()
        let retried = expectation(description: "retry succeeded")
        core.onQuiescent { retried.fulfill() }
        wait(for: [retried], timeout: 5)

        let keys = MockURLProtocol.capturedRequests
            .filter { $0.url!.path.hasSuffix("/events") }
            .compactMap { $0.value(forHTTPHeaderField: "x-idempotency-key") }
        XCTAssertGreaterThanOrEqual(keys.count, 2, "expected a failed send and a retry")
        XCTAssertEqual(Set(keys).count, 1,
                       "the retry of an identical batch must reuse the key: \(keys)")
        core.shutdown()
    }

    /// And a genuinely different batch must get a different key, or the server
    /// would discard real data.
    func testADifferentBatchGetsADifferentKey() {
        let handshake = Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8)
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake") ? .init(statusCode: 200, data: handshake)
                                                  : .init(statusCode: 202)
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
        options.batchSize = 1 // flush per event
        core.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                       options: options, environment: ["device.platform": "ios"])
        let configured = expectation(description: "configured")
        core.onQuiescent { configured.fulfill() }
        wait(for: [configured], timeout: 5)

        core.track("one", properties: [:])
        core.track("two", properties: [:])
        let done = expectation(description: "quiescent")
        core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)

        let keys = MockURLProtocol.capturedRequests
            .filter { $0.url!.path.hasSuffix("/events") }
            .compactMap { $0.value(forHTTPHeaderField: "x-idempotency-key") }
        XCTAssertEqual(Set(keys).count, keys.count, "distinct batches, distinct keys: \(keys)")
        core.shutdown()
    }
}
