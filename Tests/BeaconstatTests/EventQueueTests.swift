import XCTest
@testable import Beaconstat

final class EventQueueTests: XCTestCase {
    private final class MemStore: EventStore {
        var events: [Event] = []
        /// Set to false to simulate a store that has stopped accepting writes.
        var writable = true
        func load() -> [Event] { events }
        @discardableResult
        func save(_ e: [Event]) -> Bool {
            guard writable else { return false }
            events = e
            return true
        }
    }
    private func log() -> Logger { Logger(enabled: false, sink: { _ in }) }
    /// Memoised: `Event` now carries a unique `id` (H6), so building "the same"
    /// event twice would produce two non-equal values and break every
    /// order/content assertion below.
    private var madeEvents: [Int: Event] = [:]
    private func ev(_ n: Int) -> Event {
        if let existing = madeEvents[n] { return existing }
        let event = Event(name: "e\(n)", time: "t\(n)")
        madeEvents[n] = event
        return event
    }

    func testEnqueuePersists() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 500, logger: log())
        q.enqueue(ev(1))
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(store.events, [ev(1)]) // persisted immediately
    }

    func testLoadsExistingOnInit() {
        let store = MemStore(); store.events = [ev(1), ev(2)]
        XCTAssertEqual(EventQueue(store: store, maxQueued: 500, logger: log()).count, 2)
    }

    func testDropOldestBeyondCap() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 3, logger: log())
        for i in 1...5 { q.enqueue(ev(i)) }
        XCTAssertEqual(q.count, 3)
        XCTAssertEqual(q.nextBatch(max: 100), [ev(3), ev(4), ev(5)]) // oldest dropped
    }

    func testNextBatchCapsAtTheServersHundredEventLimit() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 1000, logger: log())
        for i in 1...150 { q.enqueue(ev(i)) }
        XCTAssertEqual(q.nextBatch(max: 1000).count, EventQueue.maxEventsPerBatch)
    }

    func testNextBatchNegativeMaxReturnsEmpty() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 500, logger: log())
        q.enqueue(ev(1))
        q.enqueue(ev(2))
        XCTAssertEqual(q.nextBatch(max: -1), [])
    }

    func testNextBatchDoesNotMutate() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 500, logger: log())
        for i in 1...5 { q.enqueue(ev(i)) }
        XCTAssertEqual(q.nextBatch(max: 2), [ev(1), ev(2)])
        XCTAssertEqual(q.nextBatch(max: 2), [ev(1), ev(2)], "selection is idempotent until checkout")
        XCTAssertEqual(q.count, 5)
    }

    func testCheckoutThenAcknowledgeDropsTheSentPrefixAndPersists() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 500, logger: log())
        for i in 1...5 { q.enqueue(ev(i)) }
        q.checkout(2)
        q.acknowledge()
        XCTAssertEqual(q.nextBatch(max: 100), [ev(3), ev(4), ev(5)])
        XCTAssertEqual(store.events, [ev(3), ev(4), ev(5)])
    }

    func testSetMaxQueuedEnforcesTheNewCapImmediately() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 500, logger: log())
        for i in 1...5 { q.enqueue(ev(i)) }
        q.setMaxQueued(2)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(store.events, [ev(4), ev(5)])
    }

    func testClearEmptiesAndPersists() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 500, logger: log())
        q.enqueue(ev(1)); q.clear()
        XCTAssertEqual(q.count, 0)
        XCTAssertEqual(store.events, [])
    }
}
