import XCTest
@testable import Beaconstat

/// L3 — `save` used to swallow every error with two `try?`, so a disk-full or
/// data-protection denial silently meant the queue was not durable and nobody
/// (host, log, or the queue itself) knew.
final class PersistenceFailureTests: XCTestCase {
    /// `/dev/null` is a character device, so it can never be a directory —
    /// `createDirectory` and `write` both fail deterministically on every
    /// Apple platform.
    private var unwritableURL: URL {
        URL(fileURLWithPath: "/dev/null/beaconstat-does-not-exist/queue.json")
    }

    func testSaveReportsFailureInsteadOfSwallowingIt() {
        let store = FileEventStore(fileURL: unwritableURL, logger: Logger(enabled: false, sink: { _ in }))
        XCTAssertFalse(store.save([Event(name: "a", time: "t")]),
                       "save must report that the events did not reach disk")
    }

    func testSaveSuccessReportsTrue() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileEventStore(fileURL: url).save([Event(name: "a", time: "t")]))
    }

    func testSaveFailureIsLogged() {
        let log = LogCollector()
        let store = FileEventStore(fileURL: unwritableURL, logger: Logger(enabled: true, sink: log.append))
        store.save([Event(name: "a", time: "t")])
        XCTAssertTrue(log.contains("could not be persisted"),
                      "expected a persistence-failure log, got: \(log.lines)")
    }

    /// The queue is the layer that knows the events are now memory-only, so it
    /// says so — once, not on every enqueue.
    func testQueueWarnsOnceThatItIsNotDurable() {
        let log = LogCollector()
        let logger = Logger(enabled: true, sink: log.append)
        let queue = EventQueue(store: FileEventStore(fileURL: unwritableURL, logger: logger),
                               maxQueued: 500, logger: logger)
        queue.enqueue(Event(name: "a", time: "t"))
        queue.enqueue(Event(name: "b", time: "t"))
        queue.enqueue(Event(name: "c", time: "t"))
        XCTAssertEqual(log.lines.filter { $0.contains("queue is no longer durable") }.count, 1,
                       "expected exactly one durability warning, got: \(log.lines)")
    }

    /// A file that exists but holds garbage is data loss, not a cold start —
    /// distinguish it from the (entirely normal) missing-file case.
    func testCorruptFileIsLoggedButStillLoadsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let log = LogCollector()
        let store = FileEventStore(fileURL: url, logger: Logger(enabled: true, sink: log.append))
        XCTAssertEqual(store.load(), [])
        XCTAssertTrue(log.contains("unreadable"), "expected a corruption log, got: \(log.lines)")
    }

    func testMissingFileIsNotLoggedAsCorruption() {
        let log = LogCollector()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcs-\(UUID().uuidString).json")
        let store = FileEventStore(fileURL: url, logger: Logger(enabled: true, sink: log.append))
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(log.contains("unreadable"),
                       "a first launch has no queue file — that is not corruption: \(log.lines)")
    }
}
