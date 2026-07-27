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

    /// Default ceiling on the encoded size of one batch (H3).
    ///
    /// 100 events with no byte budget at all could approach ~5 MB at the
    /// enforced property limits, and the reference ingest API runs behind
    /// Express's default 100 KB body-parser limit — so a full batch of large
    /// events was 413'd every single time, forever, with nothing behind it able
    /// to send. 80 KB leaves headroom for `environment` and `productVersion`,
    /// which share the same body; the core subtracts the environment's actual
    /// size from this before selecting.
    static let defaultMaxBatchBytes = 80 * 1024

    /// Never shrink the adaptive budget below this, or a server answering 413
    /// to everything would drive batches to zero events.
    static let minimumBatchBytes = 4 * 1024

    /// Absolute ceiling on ONE event, enforced at enqueue.
    ///
    /// Deliberately a fixed constant rather than the current adaptive batch
    /// budget: a 413-driven shrink must never start discarding events that are
    /// perfectly legal. 64 KB comfortably admits a maximal legitimate event
    /// (the server allows 50 property keys at 1024 chars each ≈ 56 KB) while
    /// refusing anything that could not fit in a default batch on its own.
    static let maxEventBytes = 64 * 1024

    /// Encoded size of one event, measured the way it is persisted (id
    /// included). That over-estimates the default wire size by ~48 bytes per
    /// event, which biases toward smaller batches — the safe direction.
    private static func encodedSize(_ event: Event) -> Int {
        (try? JSONEncoder().encode(event).count) ?? 0
    }

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
        // Refuse an event that could never fit in a batch by itself, at the
        // door. Queueing it would park it at the front forever: it can never be
        // sent, and nothing behind it can be selected past it (H3).
        let size = Self.encodedSize(event)
        guard size <= Self.maxEventBytes else {
            logger.debug("dropping '\(event.name)': \(size) bytes is too large to ever send "
                         + "(limit \(Self.maxEventBytes))")
            return
        }
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

    /// Events that must not be dropped while anything else could go instead
    /// (M8).
    ///
    /// Each is emitted at most once per install, per session, or per version
    /// transition, and none can be reconstructed afterwards — losing one loses
    /// an install, a session, or an upgrade outright. An arbitrary custom event
    /// is one of many and costs a data point.
    ///
    /// This was the sharp edge of front-eviction: these are enqueued *first* on
    /// a launch, so they were always the first casualties of an offline chatty
    /// session — the SDK dropped precisely the events it exists to report and
    /// kept the ones it doesn't.
    static let highValueEventNames: Set<String> = [
        "_bcs.install_detected",
        "_bcs.session_started",
        "_bcs.apple.app_updated",
    ]

    /// Brings the queue back under its cap, sacrificing the least valuable
    /// events available.
    ///
    /// Order of sacrifice:
    /// 1. ordinary pending events, oldest first;
    /// 2. high-value pending events, oldest first — only once nothing else is
    ///    left. An absolute "never evict" would let a queue of nothing but
    ///    session starts grow without bound, which is a worse failure than
    ///    dropping the oldest of them.
    ///
    /// In-flight events are never candidates: they live in `inFlight`, not
    /// `pending`. Residency is therefore bounded by
    /// `maxQueued + one batch`, and a batch being retried is no longer the
    /// preferred casualty of the next overflow.
    private func evictIfOverCap(reason: String) {
        var overflow = count - maxQueued
        guard overflow > 0 else { return }

        var survivors: [Event] = []
        survivors.reserveCapacity(pending.count)
        var droppedOrdinary = 0
        for event in pending {
            if overflow > 0, !Self.highValueEventNames.contains(event.name) {
                overflow -= 1
                droppedOrdinary += 1
                continue
            }
            survivors.append(event)
        }
        pending = survivors

        var droppedHighValue = 0
        if overflow > 0 {
            // Everything left is high-value. Bounded fallback, oldest first.
            droppedHighValue = Swift.min(overflow, pending.count)
            pending.removeFirst(droppedHighValue)
        }

        if droppedOrdinary > 0 {
            logger.debug("\(reason) — dropped \(droppedOrdinary) oldest event(s)")
        }
        if droppedHighValue > 0 {
            logger.debug("\(reason) — dropped \(droppedHighValue) oldest high-value event(s) "
                         + "(install/session/update); the queue holds nothing cheaper to drop, "
                         + "so raise maxQueuedEvents or flush more often")
        }
    }

    // MARK: - Consuming

    /// The next batch to send, **without mutating anything**, so the caller can
    /// encode and sign before committing to it (L2). Never includes an
    /// in-flight event.
    ///
    /// - Parameter maxBytes: encoded-size budget for the batch (H3). Bounds the
    ///   request so it cannot be rejected out of hand for being too big.
    ///
    /// Returns at least one event whenever anything is pending, even if that
    /// event alone exceeds the budget. Returning empty instead would recreate
    /// the very deadlock this exists to prevent: the head event could never be
    /// selected, and nothing behind it would ever send. An over-budget event
    /// goes out alone, and the server's answer decides its fate.
    func nextBatch(max: Int, maxBytes: Int = EventQueue.defaultMaxBatchBytes) -> [Event] {
        let limit = Swift.min(Swift.max(0, max), Self.maxEventsPerBatch)
        guard limit > 0 else { return [] }
        var selected: [Event] = []
        var bytes = 0
        for event in pending {
            guard selected.count < limit else { break }
            let size = Self.encodedSize(event)
            // The `!selected.isEmpty` guard is what lets an over-budget head
            // event through on its own.
            if !selected.isEmpty, bytes + size > maxBytes { break }
            selected.append(event)
            bytes += size
            if bytes >= maxBytes { break }
        }
        return selected
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
