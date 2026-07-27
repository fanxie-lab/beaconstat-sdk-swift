import Foundation

/// In-memory event queue backed by an `EventStore`. Not itself thread-safe —
/// the core touches it only on its serial queue.
final class EventQueue {
    private var events: [Event]
    private let store: EventStore
    private var maxQueued: Int
    private let logger: Logger
    /// Set once the store first refuses a write, so the "not durable" warning
    /// is emitted once rather than on every enqueue (L3).
    private var reportedNotDurable = false

    init(store: EventStore, maxQueued: Int, logger: Logger) {
        self.store = store
        self.maxQueued = max(1, maxQueued)
        self.logger = logger
        self.events = store.load()
    }

    var count: Int { events.count }
    var isEmpty: Bool { events.isEmpty }

    /// Persists, and surfaces the first failure. The whole delivery model rests
    /// on "a crash or suspension replays from disk", so a store that has stopped
    /// accepting writes is a fact the host needs in its log (L3).
    private func persist() {
        guard !store.save(events) else { return }
        guard !reportedNotDurable else { return }
        reportedNotDurable = true
        logger.debug("the event queue is no longer durable — writes to disk are failing, so "
                     + "queued events will not survive termination")
    }

    /// Applies a new cap on reconfigure, in place, so the queue *instance* is
    /// never replaced while a flush completion still holds a checked-out batch
    /// (M7). Enforces the new cap immediately rather than at the next enqueue.
    func setMaxQueued(_ newValue: Int) {
        let clamped = Swift.max(1, newValue)
        guard clamped != maxQueued else { return }
        maxQueued = clamped
        guard events.count > maxQueued else { return }
        let overflow = events.count - maxQueued
        events.removeFirst(overflow)
        logger.debug("maxQueuedEvents lowered to \(maxQueued) — dropped \(overflow) oldest event(s)")
        persist()
    }

    func enqueue(_ event: Event) {
        events.append(event)
        if events.count > maxQueued {
            let overflow = events.count - maxQueued
            events.removeFirst(overflow)
            logger.debug("queue full — dropped \(overflow) oldest event(s)")
        }
        persist()
    }

    /// Up to `min(max, 100, count)` events from the front (does not remove).
    func peekBatch(max: Int) -> [Event] {
        Array(events.prefix(Swift.min(Swift.min(Swift.max(0, max), 100), events.count)))
    }

    func removeFirst(_ n: Int) {
        guard n > 0 else { return }
        events.removeFirst(Swift.min(n, events.count))
        persist()
    }

    /// Removes AND returns up to `min(max, 100, count)` events from the front.
    /// Used by the flush "checkout" model so an in-flight batch can't be shifted
    /// by concurrent overflow eviction.
    func dequeueBatch(max: Int) -> [Event] {
        let n = Swift.min(Swift.min(Swift.max(0, max), 100), events.count)
        guard n > 0 else { return [] }
        let batch = Array(events.prefix(n))
        events.removeFirst(n)
        persist()
        return batch
    }

    /// Re-inserts a checked-out batch at the front (on retryable failure),
    /// enforcing the cap by dropping oldest.
    func prepend(_ batch: [Event]) {
        guard !batch.isEmpty else { return }
        events.insert(contentsOf: batch, at: 0)
        if events.count > maxQueued {
            let overflow = events.count - maxQueued
            events.removeFirst(overflow)
            logger.debug("queue full on requeue — dropped \(overflow) oldest event(s)")
        }
        persist()
    }

    func clear() {
        events.removeAll()
        persist()
    }
}
