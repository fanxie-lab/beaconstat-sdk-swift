import XCTest
@testable import Beaconstat

final class EventPayloadTests: XCTestCase {
    func testEmptyPropertiesNormalizeToNilAndAreOmitted() throws {
        let e = Event(name: "feature_used", time: "2026-04-19T10:30:00.000Z", properties: [:])
        XCTAssertNil(e.properties)
        let batch = EventBatch(productVersion: "1.0.0", environment: [:], events: [e])
        let json = String(data: try PayloadEncoder.encode(batch), encoding: .utf8)!
        XCTAssertFalse(json.contains("properties"))
    }

    func testEncodingIsDeterministicAndByteStable() throws {
        let e = Event(name: "feature_used", time: "2026-04-19T10:30:00.000Z",
                      properties: ["b": "2", "a": "1"])
        let batch = EventBatch(productVersion: "1.0.0",
                               environment: ["device.platform": "ios"], events: [e])
        let d1 = try PayloadEncoder.encode(batch)
        let d2 = try PayloadEncoder.encode(batch)
        XCTAssertEqual(d1, d2) // stable bytes across encodes
        let json = String(data: d1, encoding: .utf8)!
        // sortedKeys: "a" before "b"
        XCTAssertLessThan(json.range(of: "\"a\"")!.lowerBound, json.range(of: "\"b\"")!.lowerBound)
    }

    func testShapeMatchesContract() throws {
        let e = Event(name: "_bcs.install_detected", time: "2026-04-19T10:30:00.000Z")
        let batch = EventBatch(productVersion: "1.5.0",
                               environment: ["device.platform": "ios"], events: [e])
        let json = String(data: try PayloadEncoder.encode(batch), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"productVersion\":\"1.5.0\""))
        XCTAssertTrue(json.contains("\"name\":\"_bcs.install_detected\""))
    }
}
