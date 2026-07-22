import Foundation

/// In-memory event queue backed by an `EventStore`. Not itself thread-safe —
/// the core touches it only on its serial queue.
final class EventQueue {
    private var events: [Event]
    private let store: EventStore
    private let maxQueued: Int
    private let logger: Logger

    init(store: EventStore, maxQueued: Int, logger: Logger) {
        self.store = store
        self.maxQueued = max(1, maxQueued)
        self.logger = logger
        self.events = store.load()
    }

    var count: Int { events.count }

    func enqueue(_ event: Event) {
        events.append(event)
        if events.count > maxQueued {
            let overflow = events.count - maxQueued
            events.removeFirst(overflow)
            logger.debug("queue full — dropped \(overflow) oldest event(s)")
        }
        store.save(events)
    }

    /// Up to `min(max, 100, count)` events from the front (does not remove).
    func peekBatch(max: Int) -> [Event] {
        Array(events.prefix(Swift.min(Swift.min(Swift.max(0, max), 100), events.count)))
    }

    func removeFirst(_ n: Int) {
        guard n > 0 else { return }
        events.removeFirst(Swift.min(n, events.count))
        store.save(events)
    }
}
