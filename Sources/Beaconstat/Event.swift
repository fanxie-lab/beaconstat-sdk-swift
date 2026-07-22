import Foundation

/// One tracked event. `time` is an ISO 8601 string; `properties` values are strings.
struct Event: Codable, Equatable {
    let name: String
    let time: String
    let properties: [String: String]?

    init(name: String, time: String, properties: [String: String]? = nil) {
        self.name = name
        self.time = time
        self.properties = (properties?.isEmpty ?? true) ? nil : properties
    }
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
    static func encode(_ batch: EventBatch) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(batch)
    }
}
