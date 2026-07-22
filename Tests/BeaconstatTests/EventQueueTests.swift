import XCTest
@testable import Beaconstat

final class EventQueueTests: XCTestCase {
    private final class MemStore: EventStore {
        var events: [Event] = []
        func load() -> [Event] { events }
        func save(_ e: [Event]) { events = e }
    }
    private func log() -> Logger { Logger(enabled: false, sink: { _ in }) }
    private func ev(_ n: Int) -> Event { Event(name: "e\(n)", time: "t\(n)") }

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
        XCTAssertEqual(q.peekBatch(max: 100), [ev(3), ev(4), ev(5)]) // oldest dropped
    }

    func testPeekBatchCapsAt100() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 1000, logger: log())
        for i in 1...150 { q.enqueue(ev(i)) }
        XCTAssertEqual(q.peekBatch(max: 100).count, 100)
    }

    func testRemoveFirstDropsSentPrefixAndPersists() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 500, logger: log())
        for i in 1...5 { q.enqueue(ev(i)) }
        q.removeFirst(2)
        XCTAssertEqual(q.peekBatch(max: 100), [ev(3), ev(4), ev(5)])
        XCTAssertEqual(store.events, [ev(3), ev(4), ev(5)])
    }

    func testPeekBatchNegativeMaxReturnsEmpty() {
        let store = MemStore()
        let q = EventQueue(store: store, maxQueued: 500, logger: log())
        q.enqueue(ev(1))
        q.enqueue(ev(2))
        XCTAssertEqual(q.peekBatch(max: -1), [])
    }
}
