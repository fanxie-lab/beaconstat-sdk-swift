import Foundation

/// Durable store for the event queue. Survives process termination.
protocol EventStore {
    func load() -> [Event]
    /// Persists `events`, replacing whatever was there.
    ///
    /// - Returns: `true` when the events reached disk. A `false` here means the
    ///   queue is memory-only from now on, which the caller must not ignore —
    ///   the whole delivery model assumes a crash or suspension replays from
    ///   disk (L3).
    @discardableResult
    func save(_ events: [Event]) -> Bool
}

/// Atomic JSON-file store. A missing file loads as empty (a normal first
/// launch); a corrupt one also loads as empty, but says so.
final class FileEventStore: EventStore {
    private let fileURL: URL
    private let logger: Logger

    init(fileURL: URL, logger: Logger = Logger(enabled: false, sink: { _ in })) {
        self.fileURL = fileURL
        self.logger = logger
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            logger.debug("could not create the queue directory: \(error)")
        }
    }

    func load() -> [Event] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // No file is the overwhelmingly common case (first launch, or a
            // fully drained queue). Not worth a line.
            return []
        }
        do {
            return try JSONDecoder().decode([Event].self, from: data)
        } catch {
            logger.debug("queued events were unreadable (\(data.count) bytes) and have been "
                         + "discarded: \(error)")
            return []
        }
    }

    @discardableResult
    func save(_ events: [Event]) -> Bool {
        do {
            let data = try JSONEncoder().encode(events)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            // Disk-full, a data-protection denial before first unlock, or a
            // sandbox refusal. Previously two `try?` swallowed all three.
            logger.debug("\(events.count) queued event(s) could not be persisted: \(error)")
            return false
        }
    }
}
