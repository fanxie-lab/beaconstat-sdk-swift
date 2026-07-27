import XCTest
@testable import Beaconstat

/// H2 — the queue used to persist the *shortened* array the instant a batch was
/// checked out, so the events existed only in the completion closure's capture
/// list. A suspension or crash before the POST returned lost them from disk and
/// from memory. The model is now "mark in-flight, delete on ack".
final class EventQueueDurabilityTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bcs-\(UUID().uuidString).json")
    }
    private func log() -> Logger { Logger(enabled: false, sink: { _ in }) }
    private func ev(_ n: Int) -> Event { Event(name: "e\(n)", time: "t\(n)") }

    /// The review's test gap 7, inverted: dequeue, drop the instance, reload
    /// from disk. Under the old contract the batch was gone.
    func testCheckedOutBatchSurvivesProcessTermination() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            let queue = EventQueue(store: FileEventStore(fileURL: url), maxQueued: 500, logger: log())
            for i in 1...5 { queue.enqueue(ev(i)) }
            let batch = queue.nextBatch(max: 2)
            XCTAssertEqual(batch, [ev(1), ev(2)])
            queue.checkout(batch.count)
            // ...and the process dies here, mid-POST.
        }
        let reloaded = EventQueue(store: FileEventStore(fileURL: url), maxQueued: 500, logger: log())
        XCTAssertEqual(reloaded.count, 5, "an unacknowledged batch must replay, not vanish")
        XCTAssertEqual(reloaded.nextBatch(max: 5), (1...5).map(ev),
                       "and it must replay in its original order, at the front")
    }

    /// The other half of the contract: once the server acknowledges, the batch
    /// is gone from disk — an ack must not leave events behind to be resent.
    func testAcknowledgedBatchIsRemovedFromDisk() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            let queue = EventQueue(store: FileEventStore(fileURL: url), maxQueued: 500, logger: log())
            for i in 1...5 { queue.enqueue(ev(i)) }
            queue.checkout(queue.nextBatch(max: 2).count)
            queue.acknowledge()
        }
        let reloaded = EventQueue(store: FileEventStore(fileURL: url), maxQueued: 500, logger: log())
        XCTAssertEqual(reloaded.nextBatch(max: 10), [ev(3), ev(4), ev(5)])
    }

    /// No double-send: an in-flight batch must be invisible to the next
    /// selection even if one somehow runs before the completion arrives.
    func testInFlightEventsAreNeverSelectedAgain() {
        let queue = EventQueue(store: FileEventStore(fileURL: tempURL()), maxQueued: 500, logger: log())
        for i in 1...5 { queue.enqueue(ev(i)) }
        queue.checkout(queue.nextBatch(max: 2).count)
        XCTAssertEqual(queue.nextBatch(max: 10), [ev(3), ev(4), ev(5)])
        XCTAssertEqual(queue.inFlightCount, 2)
        XCTAssertEqual(queue.count, 5, "in-flight events are still queued — just not sendable")
        XCTAssertEqual(queue.pendingCount, 3)
    }

    /// A retryable failure returns the batch to the front, in order, losing
    /// nothing — the old `prepend` re-inserted and then evicted (M8).
    func testReleaseRestoresTheBatchAtTheFrontInOrder() {
        let queue = EventQueue(store: FileEventStore(fileURL: tempURL()), maxQueued: 500, logger: log())
        for i in 1...5 { queue.enqueue(ev(i)) }
        queue.checkout(queue.nextBatch(max: 2).count)
        queue.release()
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertEqual(queue.nextBatch(max: 10), (1...5).map(ev))
    }

    /// `checkout` and `release` change no on-disk content, so neither needs a
    /// write. This halves the disk traffic of a failed flush AND is what makes
    /// the crash-replay property hold.
    func testCheckoutAndReleaseDoNotRewriteTheFile() {
        final class CountingStore: EventStore {
            var events: [Event] = []
            var saves = 0
            func load() -> [Event] { events }
            @discardableResult
            func save(_ e: [Event]) -> Bool { saves += 1; events = e; return true }
        }
        let store = CountingStore()
        let queue = EventQueue(store: store, maxQueued: 500, logger: log())
        for i in 1...5 { queue.enqueue(ev(i)) }
        let afterEnqueues = store.saves
        queue.checkout(queue.nextBatch(max: 2).count)
        queue.release()
        XCTAssertEqual(store.saves, afterEnqueues, "checkout/release are pure in-memory bookkeeping")
        queue.checkout(queue.nextBatch(max: 2).count)
        queue.acknowledge()
        XCTAssertEqual(store.saves, afterEnqueues + 1, "only the ack shortens the file")
    }

    /// Events enqueued while a batch is in flight must go behind it, not in
    /// front of it, or a release would reorder the queue.
    func testEnqueueDuringFlightGoesBehindTheInFlightBatch() {
        let queue = EventQueue(store: FileEventStore(fileURL: tempURL()), maxQueued: 500, logger: log())
        for i in 1...3 { queue.enqueue(ev(i)) }
        queue.checkout(queue.nextBatch(max: 2).count)
        queue.enqueue(ev(4))
        queue.release()
        XCTAssertEqual(queue.nextBatch(max: 10), [ev(1), ev(2), ev(3), ev(4)])
    }

    /// `clear()` (opt-out) must take the in-flight batch with it, or the queue
    /// would be permanently wedged: nothing acknowledges it and nothing else
    /// can be checked out while it is held.
    func testClearAlsoDropsTheInFlightBatch() {
        let queue = EventQueue(store: FileEventStore(fileURL: tempURL()), maxQueued: 500, logger: log())
        for i in 1...3 { queue.enqueue(ev(i)) }
        queue.checkout(queue.nextBatch(max: 2).count)
        queue.clear()
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertTrue(queue.nextBatch(max: 10).isEmpty)
    }

    /// Defensive: the `flushing` flag guarantees one batch at a time, but a
    /// second checkout must not silently corrupt the in-flight set if that ever
    /// regresses.
    func testSecondCheckoutWhileOneIsHeldIsRefused() {
        let queue = EventQueue(store: FileEventStore(fileURL: tempURL()), maxQueued: 500, logger: log())
        for i in 1...5 { queue.enqueue(ev(i)) }
        queue.checkout(2)
        queue.checkout(2)
        XCTAssertEqual(queue.inFlightCount, 2, "the second checkout is a no-op")
        XCTAssertEqual(queue.pendingCount, 3)
    }

    func testAcknowledgeAndReleaseAreNoOpsWithNothingInFlight() {
        let queue = EventQueue(store: FileEventStore(fileURL: tempURL()), maxQueued: 500, logger: log())
        queue.enqueue(ev(1))
        queue.acknowledge()
        queue.release()
        XCTAssertEqual(queue.count, 1)
    }
}
