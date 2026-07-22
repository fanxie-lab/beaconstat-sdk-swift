import Foundation

/// Durable store for the event queue. Survives process termination.
protocol EventStore {
    func load() -> [Event]
    func save(_ events: [Event])
}

/// Atomic JSON-file store. Missing or corrupt file loads as empty.
final class FileEventStore: EventStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func load() -> [Event] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([Event].self, from: data) else {
            return []
        }
        return events
    }

    func save(_ events: [Event]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
