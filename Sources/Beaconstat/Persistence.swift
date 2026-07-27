import Foundation

/// Durable store for the event queue. Survives process termination.
/// `Sendable` so the queue that owns one can be captured alongside the rest of
/// the core's state; `FileEventStore` is stateless apart from two immutable lets.
protocol EventStore: Sendable {
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
final class FileEventStore: EventStore {  // both members are immutable `let`s
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
            excludeFromBackup()
            return true
        } catch {
            // Disk-full, a data-protection denial before first unlock, or a
            // sandbox refusal. Previously two `try?` swallowed all three.
            logger.debug("\(events.count) queued event(s) could not be persisted: \(error)")
            return false
        }
    }

    /// Keeps transient telemetry out of iCloud/iTunes backups (L4). Restoring a
    /// backup onto a second device would otherwise replay whatever happened to
    /// be queued when it was taken.
    ///
    /// Applied to the queue FILE, never to its directory. `identity.json` lives
    /// in the same directory and Wave 1 made it deliberately durable;
    /// `isExcludedFromBackup` on a directory is inherited by everything inside
    /// it, so excluding the directory would silently take identity with it and
    /// a restored device would report a brand-new install.
    ///
    /// Reapplied on every successful save rather than once: `.atomic` writes to
    /// a temp file and renames it into place, so each save replaces the inode
    /// the attribute was set on. Cheap — it is a single `setattrlist` against a
    /// file we have just written and whose metadata is already hot.
    private func excludeFromBackup() {
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            logger.debug("could not exclude the queue file from backups: \(error)")
        }
    }
}
