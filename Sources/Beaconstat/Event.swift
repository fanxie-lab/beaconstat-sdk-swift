import Foundation

/// One tracked event. `time` is an ISO 8601 string; `properties` values are strings.
struct Event: Codable, Equatable {
    /// Stable per-event idempotency id (H6).
    ///
    /// Generated **once**, when the event is created, and carried through the
    /// queue file unchanged — so every retry of an event presents the same id.
    /// That is the whole point: a lost 202 (cellular handoff, or a timeout
    /// firing after the server had already committed) makes the client resend
    /// identical events, and an id minted per *attempt* would be
    /// indistinguishable from genuinely new data.
    ///
    /// See `EventBatch` for why it is not on the wire by default.
    let id: String
    let name: String
    let time: String
    let properties: [String: String]?

    init(name: String, time: String, properties: [String: String]? = nil,
         id: String = UUID().uuidString.lowercased()) {
        self.id = id
        self.name = name
        self.time = time
        self.properties = (properties?.isEmpty ?? true) ? nil : properties
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, time, properties
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Optional on the way in: a `queue.json` written by 1.0.0 has no ids,
        // and failing to decode would discard the whole file on upgrade — a
        // worse bug than the one the id fixes.
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? UUID().uuidString.lowercased()
        self.name = try container.decode(String.self, forKey: .name)
        self.time = try container.decode(String.self, forKey: .time)
        self.properties = try container.decodeIfPresent([String: String].self, forKey: .properties)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Include by default. The wire encoder opts *out*, deliberately: a
        // forgotten flag then costs a redundant field on disk rather than
        // silently dropping the id, which would be data loss.
        if encoder.userInfo[.omitEventId] as? Bool != true {
            try container.encode(id, forKey: .id)
        }
        try container.encode(name, forKey: .name)
        try container.encode(time, forKey: .time)
        try container.encodeIfPresent(properties, forKey: .properties)
    }
}

extension CodingUserInfoKey {
    /// Set on the wire encoder to keep `Event.id` out of the request body.
    static let omitEventId = CodingUserInfoKey(rawValue: "com.beaconstat.omitEventId")!
}

/// The `/v1/events` request body.
struct EventBatch: Encodable {
    let productVersion: String
    let environment: [String: String]
    let events: [Event]
}

/// Byte-stable JSON. Key order is irrelevant to the server; `.sortedKeys`
/// only makes output deterministic for tests. Encode ONCE, sign+send the
/// same `Data` — never re-encode between signing and sending.
enum PayloadEncoder {
    /// - Parameter includeEventIds: put each event's `id` in the body.
    ///
    ///   **Off by default, and it must stay off until the ingest API declares
    ///   the field.** The API's global `ValidationPipe` runs with
    ///   `forbidNonWhitelisted: true`, and `EventDto` declares only
    ///   `name`/`time`/`properties`. class-validator applies the whitelist to
    ///   nested objects with the same options, so an unknown `id` does not get
    ///   stripped — it produces `400 property id should not exist` and the
    ///   **entire batch** is rejected, all 100 events, not just the offending
    ///   one. Turning this on against a server that hasn't shipped the matching
    ///   `EventDto` change is a total ingest outage, not a degradation.
    static func encode(_ batch: EventBatch, includeEventIds: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[.omitEventId] = !includeEventIds
        return try encoder.encode(batch)
    }
}

/// Per-batch idempotency key (H6).
///
/// The half of the fix that ships today: unlike a body field, a header passes
/// ingest untouched (headers are not whitelisted) and does not disturb the
/// signature, whose canonical payload is `timestamp.publicKey.sha256(body)`.
/// It is also the cheapest thing for the server to adopt — a seen-key check
/// with a TTL, no DTO change, no ClickHouse migration, no materialized-view
/// rework.
enum IdempotencyKey {
    /// Derived from the member event ids, in order. Stable across retries of
    /// the same batch — which is exactly when dedup is needed — and different
    /// the moment the composition changes, so a genuinely new batch is never
    /// mistaken for a replay.
    static func forBatch(_ events: [Event]) -> String {
        Signer.sha256Hex(Data(events.map(\.id).joined(separator: "\n").utf8))
    }
}
