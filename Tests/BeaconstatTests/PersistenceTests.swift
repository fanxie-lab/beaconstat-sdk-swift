import XCTest
@testable import Beaconstat

final class PersistenceTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bcs-\(UUID().uuidString).json")
    }

    func testSaveThenLoadRoundTrips() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = FileEventStore(fileURL: url)
        let events = [Event(name: "a", time: "2026-04-19T10:30:00.000Z"),
                      Event(name: "b", time: "2026-04-19T10:31:00.000Z", properties: ["k": "v"])]
        store.save(events)
        XCTAssertEqual(FileEventStore(fileURL: url).load(), events) // fresh instance = cold relaunch
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(FileEventStore(fileURL: tempURL()).load(), [])
    }

    func testCorruptFileLoadsEmpty() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(FileEventStore(fileURL: url).load(), [])
    }

    func testSaveEmptyClearsFile() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = FileEventStore(fileURL: url)
        store.save([Event(name: "a", time: "t")])
        store.save([])
        XCTAssertEqual(FileEventStore(fileURL: url).load(), [])
    }
}
