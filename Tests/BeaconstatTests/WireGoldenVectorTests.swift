import XCTest
@testable import Beaconstat

/// Test gap 5 — the byte-exact wire contract.
///
/// The suite had a "golden vector" in `SignerTests`, but its body was a
/// **hand-written string `PayloadEncoder` never produces**: it read
/// `{"productVersion":…,"environment":…,"events":…}` while the encoder emits
/// `.sortedKeys`, i.e. `{"environment":…,"events":…,"productVersion":…}`. So it
/// pinned the crypto and not the format. Every other wire assertion in the suite
/// was a `body.contains("…")` substring check, which cannot see a renamed key, a
/// re-nested object, a dropped field, or a changed key order.
///
/// This file asserts the encoder's **exact bytes**, and derives the body hash,
/// the signature and the idempotency key from those same bytes. It is the single
/// highest-value test for catching drift against ingest.
///
/// ## Coordination with the backend
///
/// The same fixture is asserted from the API side in
/// `apps/api/src/sdk/sdk.wire-contract.spec.ts`, which takes the identical byte
/// string and checks that
///
/// 1. it satisfies `EventsRequestDto` under the global `ValidationPipe`
///    (`whitelist: true, forbidNonWhitelisted: true`), and
/// 2. `SignatureGuard`'s algorithm over those raw bytes reproduces
///    `Self.expectedSignature`.
///
/// If either side changes the format, exactly one of the two tests goes red and
/// names the other. Both were also reproduced independently with
/// `openssl dgst -sha256` / `-hmac`, so neither implementation is grading its
/// own homework.
///
/// Keep the two files in sync by hand. They are in different repositories — the
/// SDK is a submodule — so a shared fixture file is not available.
final class WireGoldenVectorTests: XCTestCase {
    // MARK: - The fixture

    static let publicKey = "bcs_pub_abcdef0123456789"
    static let hmacSecret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    static let timestamp = "2026-04-19T10:30:00.000Z"
    static let sessionId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

    /// Fixed ids so the vector is reproducible. In production these are random
    /// per event and generated once, at creation (H6).
    static let installEventId = "11111111-2222-3333-4444-555555555555"
    static let featureEventId = "66666666-7777-8888-9999-aaaaaaaaaaaa"

    /// Deliberately covers the cases that actually break against ingest:
    /// a reserved event name (must be in the server's registry), a user event, a
    /// universal reserved property key (`_bcs.session.id`, allowed on any
    /// event), ordinary properties, a fractional-second timestamp, and dotted
    /// environment keys.
    static func fixture() -> EventBatch {
        EventBatch(
            productVersion: "1.5.0",
            environment: ["device.platform": "ios",
                          "device.os_version": "17.4",
                          "sdk.name": "beaconstat-swift",
                          "sdk.version": "2.0.0"],
            events: [
                Event(name: "_bcs.install_detected", time: "2026-04-19T10:30:00.000Z",
                      properties: ["_bcs.session.id": sessionId], id: installEventId),
                Event(name: "feature_used", time: "2026-04-19T10:30:01.250Z",
                      properties: ["feature": "export", "format": "pdf",
                                   "_bcs.session.id": sessionId], id: featureEventId),
            ])
    }

    // MARK: - Golden bytes (default: ids stay off the wire)

    /// Raw string literal so the inner quotes are literal and this is
    /// byte-identical to what goes out. 459 bytes.
    // swiftlint:disable line_length
    static let expectedBody = #"{"environment":{"device.os_version":"17.4","device.platform":"ios","sdk.name":"beaconstat-swift","sdk.version":"2.0.0"},"events":[{"name":"_bcs.install_detected","properties":{"_bcs.session.id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301"},"time":"2026-04-19T10:30:00.000Z"},{"name":"feature_used","properties":{"_bcs.session.id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","feature":"export","format":"pdf"},"time":"2026-04-19T10:30:01.250Z"}],"productVersion":"1.5.0"}"#

    /// With `sendEventIds = true`. 547 bytes. Off by default because the
    /// reference API's `EventDto` does not declare `id` and the pipe runs
    /// `forbidNonWhitelisted: true`, so an unknown property is not stripped — it
    /// returns `400 property id should not exist` and rejects the **whole
    /// batch**. Pinned anyway, so the day ingest adds the field the client half
    /// is already specified.
    static let expectedBodyWithIds = #"{"environment":{"device.os_version":"17.4","device.platform":"ios","sdk.name":"beaconstat-swift","sdk.version":"2.0.0"},"events":[{"id":"11111111-2222-3333-4444-555555555555","name":"_bcs.install_detected","properties":{"_bcs.session.id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301"},"time":"2026-04-19T10:30:00.000Z"},{"id":"66666666-7777-8888-9999-aaaaaaaaaaaa","name":"feature_used","properties":{"_bcs.session.id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","feature":"export","format":"pdf"},"time":"2026-04-19T10:30:01.250Z"}],"productVersion":"1.5.0"}"#
    // swiftlint:enable line_length

    /// `openssl dgst -sha256` over `expectedBody`.
    static let expectedBodyHash = "43234fae1506a8ef6100aed2c504885ba5985b9f0d0d60e3d57479e5ba34e269"
    /// `openssl dgst -sha256 -hmac <hmacSecret>` over
    /// `"<timestamp>.<publicKey>.<expectedBodyHash>"`.
    static let expectedSignature = "9c8be38825fe6973550a821f76f3f420fef90362c7f39548076005b73b46dd25"
    /// `sha256` of the two event ids joined by a newline.
    static let expectedIdempotencyKey =
        "0490254363a40918e6b658ebdea0eb3867097e51f1940dad6eb0544d794d936c"

    // MARK: - The assertions

    /// The one the review asked for. Not `contains`, not a decoded comparison —
    /// the exact bytes.
    func testEncoderProducesTheGoldenBytes() throws {
        let encoded = try PayloadEncoder.encode(Self.fixture())
        XCTAssertEqual(String(data: encoded, encoding: .utf8), Self.expectedBody)
        XCTAssertEqual(encoded, Data(Self.expectedBody.utf8))
        XCTAssertEqual(encoded.count, 459)
    }

    func testEncoderProducesTheGoldenBytesWithEventIdsEnabled() throws {
        let encoded = try PayloadEncoder.encode(Self.fixture(), includeEventIds: true)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), Self.expectedBodyWithIds)
        XCTAssertEqual(encoded.count, 547)
    }

    /// The default must keep `id` off the wire. Enabling it against a server
    /// that has not shipped the matching `EventDto` is a total ingest outage —
    /// all 100 events rejected, not a partial degradation — so this is a
    /// safety assertion, not a formatting one.
    func testEventIdsAreAbsentFromTheDefaultBody() throws {
        let encoded = try PayloadEncoder.encode(Self.fixture())
        let body = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(body.contains("\"id\""))
        XCTAssertFalse(body.contains(Self.installEventId))
        XCTAssertFalse(body.contains(Self.featureEventId))
        XCTAssertFalse(BeaconstatOptions().sendEventIds, "the default must stay off")
    }

    /// Top-level keys, in the exact order the encoder emits them. The review's
    /// point: the old vector claimed a different order, and nothing noticed.
    func testTopLevelKeyOrderIsAlphabetical() throws {
        let body = try XCTUnwrap(String(data: PayloadEncoder.encode(Self.fixture()), encoding: .utf8))
        XCTAssertTrue(body.hasPrefix(#"{"environment":"#))
        let environmentIndex = try XCTUnwrap(body.range(of: #""environment":"#))
        let eventsIndex = try XCTUnwrap(body.range(of: #""events":"#))
        let productIndex = try XCTUnwrap(body.range(of: #""productVersion":"#))
        XCTAssertTrue(environmentIndex.lowerBound < eventsIndex.lowerBound)
        XCTAssertTrue(eventsIndex.lowerBound < productIndex.lowerBound)
    }

    /// The three field names the server's `EventsRequestDto` declares, and no
    /// others at the top level. `forbidNonWhitelisted` means an extra one is a
    /// 400 for the whole batch.
    func testTopLevelFieldsAreExactlyWhatTheIngestDTODeclares() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: PayloadEncoder.encode(Self.fixture()))
                as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["productVersion", "environment", "events"])
    }

    /// Same, per event: `EventDto` declares `name`, `time`, `properties`.
    func testEventFieldsAreExactlyWhatTheIngestDTODeclares() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: PayloadEncoder.encode(Self.fixture()))
                as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        for event in events {
            XCTAssertTrue(Set(event.keys).isSubset(of: ["name", "time", "properties"]),
                          "unexpected event field: \(event.keys)")
            XCTAssertNotNil(event["name"])
            XCTAssertNotNil(event["time"])
        }
    }

    // MARK: - Crypto over the real bytes

    /// Both reproduced with `openssl`, and asserted here over the bytes the
    /// encoder actually emits rather than a hand-written approximation of them.
    func testBodyHashAndSignatureOverTheGoldenBytes() throws {
        let encoded = try PayloadEncoder.encode(Self.fixture())
        XCTAssertEqual(Signer.sha256Hex(encoded), Self.expectedBodyHash)
        XCTAssertEqual(Signer.sign(body: encoded, publicKey: Self.publicKey,
                                   hmacSecret: Self.hmacSecret, timestamp: Self.timestamp),
                       Self.expectedSignature)
    }

    /// The canonical payload the server rebuilds in `signature.guard.ts`:
    /// `timestamp + "." + publicKey + "." + sha256(rawBody)`.
    func testCanonicalPayloadMatchesTheServerFormula() {
        XCTAssertEqual(
            Signer.canonicalPayload(timestamp: Self.timestamp, publicKey: Self.publicKey,
                                    bodyHash: Self.expectedBodyHash),
            "\(Self.timestamp).\(Self.publicKey).\(Self.expectedBodyHash)")
    }

    func testIdempotencyKeyOverTheGoldenEvents() {
        XCTAssertEqual(IdempotencyKey.forBatch(Self.fixture().events),
                       Self.expectedIdempotencyKey)
    }

    /// The key must be stable across retries of the same batch — that is the
    /// entire point (H6) — and must change when the composition does.
    func testIdempotencyKeyIsStableAcrossRetriesAndUniquePerComposition() {
        let events = Self.fixture().events
        XCTAssertEqual(IdempotencyKey.forBatch(events), IdempotencyKey.forBatch(events))
        XCTAssertNotEqual(IdempotencyKey.forBatch(events),
                          IdempotencyKey.forBatch(Array(events.dropLast())))
        XCTAssertNotEqual(IdempotencyKey.forBatch(events),
                          IdempotencyKey.forBatch(events.reversed()))
    }

    // MARK: - End to end

    /// The bytes on the actual wire must be the golden bytes, and the headers
    /// must carry the signature computed over exactly those bytes — the
    /// sign-then-send discipline, checked against a fixed vector rather than
    /// against whatever the code happened to produce.
    func testTheRequestOnTheWireCarriesTheGoldenBytesAndSignature() throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { _ in .init(statusCode: 202) }

        let transport = Transport(session: .mocked(),
                                  baseURL: URL(string: "https://ingest.beaconstat.com")!,
                                  logger: Logger(enabled: false, sink: { _ in }))
        let bodyData = try PayloadEncoder.encode(Self.fixture())
        let signature = Signer.sign(body: bodyData, publicKey: Self.publicKey,
                                    hmacSecret: Self.hmacSecret, timestamp: Self.timestamp)
        let sent = expectation(description: "sent")
        transport.sendBatch(bodyData: bodyData, apiKey: Self.publicKey, siteToken: "bcs_tok_z",
                            signature: signature, timestamp: Self.timestamp, isTest: false,
                            idempotencyKey: Self.expectedIdempotencyKey) { _ in sent.fulfill() }
        wait(for: [sent], timeout: 3)

        let captured = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(captured.body, Data(Self.expectedBody.utf8),
                       "the transport altered the signed bytes")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "x-signature"),
                       Self.expectedSignature)
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "x-timestamp"), Self.timestamp)
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "x-api-key"), Self.publicKey)
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "x-site-token"), "bcs_tok_z")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "x-idempotency-key"),
                       Self.expectedIdempotencyKey)
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured.request.url?.path, "/v1/events")
    }

    /// The header set is part of the contract too: the guard chain reads
    /// `x-api-key`, `x-site-token`, `x-signature` and `x-timestamp`, and
    /// `x-idempotency-key` is deliberately *outside* the signature's canonical
    /// payload so it cannot invalidate it.
    func testIdempotencyHeaderIsOutsideTheSignedPayload() throws {
        let bodyData = try PayloadEncoder.encode(Self.fixture())
        let withKey = Signer.sign(body: bodyData, publicKey: Self.publicKey,
                                  hmacSecret: Self.hmacSecret, timestamp: Self.timestamp)
        // Signing does not take the idempotency key at all — if it ever did,
        // this test would have to change, which is the alarm.
        XCTAssertEqual(withKey, Self.expectedSignature)
    }
}
