import Foundation

/// Durable event queue backed by an `EventStore`. Not itself thread-safe — the
/// core touches it only on its serial queue.
///
/// ## Delivery model: mark in-flight, delete on ack
///
/// The logical queue is `inFlight + pending`, in that order. A flush *checks
/// out* a prefix of `pending` into `inFlight`; the on-disk contents are
/// unchanged, because the events are still queued — they are just not
/// selectable again. Only an `acknowledge()` shortens the file.
///
/// That inversion is the whole H2 fix. The old model deleted the batch from
/// disk at checkout and re-`prepend`ed it if the send failed, so the events
/// existed *only* in a completion closure's capture list for the duration of
/// the request. A background suspension or a jetsam kill before the POST
/// returned meant the completion never ran and the batch was gone from disk and
/// from memory — including `session_started` and `install_detected` on a first
/// run. Now an unacknowledged batch is still on disk, so termination replays it.
///
/// It is also cheaper: `checkout` and `release` write nothing at all.
final class EventQueue {
    /// The server caps a batch at 100 events (`@ArrayMaxSize(100)` on
    /// `EventsRequestDto`), so there is no point selecting more.
    static let maxEventsPerBatch = 100

    /// Checked out and awaiting acknowledgement. Always the logical front of
    /// the queue, and never a candidate for selection or eviction.
    private var inFlight: [Event] = []
    /// Everything not checked out, oldest first.
    private var pending: [Event]
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
        // Everything loads as pending: a batch that was in flight when the
        // process died has no acknowledgement, so it replays.
        self.pending = store.load()
    }

    /// Everything queued, including a batch currently in flight.
    var count: Int { inFlight.count + pending.count }
    var isEmpty: Bool { inFlight.isEmpty && pending.isEmpty }
    /// Everything that could be sent right now.
    var pendingCount: Int { pending.count }
    var inFlightCount: Int { inFlight.count }

    // MARK: - Persistence

    /// Persists the whole logical queue, and surfaces the first failure. The
    /// delivery model rests on "a crash or suspension replays from disk", so a
    /// store that has stopped accepting writes is a fact the host needs (L3).
    private func persist() {
        guard !store.save(inFlight + pending) else { return }
        guard !reportedNotDurable else { return }
        reportedNotDurable = true
        logger.debug("the event queue is no longer durable — writes to disk are failing, so "
                     + "queued events will not survive termination")
    }

    // MARK: - Producing

    func enqueue(_ event: Event) {
        pending.append(event)
        evictIfOverCap(reason: "queue full")
        persist()
    }

    /// Applies a new cap on reconfigure, in place, so the queue *instance* is
    /// never replaced while a flush completion still holds a checked-out batch
    /// (M7). Enforces the new cap immediately rather than at the next enqueue.
    func setMaxQueued(_ newValue: Int) {
        let clamped = Swift.max(1, newValue)
        guard clamped != maxQueued else { return }
        maxQueued = clamped
        guard count > maxQueued else { return }
        evictIfOverCap(reason: "maxQueuedEvents lowered to \(maxQueued)")
        persist()
    }

    private func evictIfOverCap(reason: String) {
        let overflow = count - maxQueued
        guard overflow > 0 else { return }
        let dropped = Swift.min(overflow, pending.count)
        guard dropped > 0 else { return }
        pending.removeFirst(dropped)
        logger.debug("\(reason) — dropped \(dropped) oldest event(s)")
    }

    // MARK: - Consuming

    /// The next batch to send, **without mutating anything**, so the caller can
    /// encode and sign before committing to it (L2). Never includes an
    /// in-flight event.
    func nextBatch(max: Int) -> [Event] {
        let n = Swift.min(Swift.min(Swift.max(0, max), Self.maxEventsPerBatch), pending.count)
        guard n > 0 else { return [] }
        return Array(pending.prefix(n))
    }

    /// Moves the first `n` pending events into the in-flight set.
    ///
    /// Writes nothing: the on-disk contents are byte-identical either way,
    /// which is exactly what makes an interrupted send replay instead of
    /// disappear.
    func checkout(_ n: Int) {
        guard inFlight.isEmpty else {
            // The core's `flushing` flag already guarantees one at a time; this
            // is here so a regression is loud rather than silently duplicating.
            logger.debug("refusing to check out a second batch while \(inFlight.count) "
                         + "event(s) are still in flight")
            return
        }
        let n = Swift.min(Swift.max(0, n), pending.count)
        guard n > 0 else { return }
        inFlight = Array(pending.prefix(n))
        pending.removeFirst(n)
    }

    /// The batch is finished with — delivered, or rejected in a way that
    /// retrying can never fix. This is the only path that shortens the file.
    func acknowledge() {
        guard !inFlight.isEmpty else { return }
        inFlight = []
        persist()
        // An ack can put us under the cap, but never over it, so no eviction.
    }

    /// The send failed in a retryable way: un-mark the batch so it is selectable
    /// again. It never left its position, so nothing is reordered and — unlike
    /// the old `prepend` — nothing is evicted to make room for it.
    func release() {
        guard !inFlight.isEmpty else { return }
        pending.insert(contentsOf: inFlight, at: 0)
        inFlight = []
        // No `persist()`: `inFlight + pending` is unchanged, so the file already
        // holds exactly this.
    }

    func clear() {
        // Takes the in-flight batch too. Leaving it would wedge the queue
        // permanently: nothing will acknowledge it, and `checkout` refuses
        // while it is held.
        inFlight = []
        pending = []
        persist()
    }
}
