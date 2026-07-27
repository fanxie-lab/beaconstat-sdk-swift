import XCTest
@testable import Beaconstat

/// L7 — `track()` caps a user event at 49 properties, but the loop that applied
/// the cap iterated a `Dictionary`. Swift seeds its hasher per process, so
/// *which* 49 of 60 keys survived changed from run to run — the review saw it
/// in the suite's own output (`dropping key: k27`, `k55`, `k39`, …).
///
/// A host that sends more properties than the cap allows should at least get the
/// same columns in their warehouse every launch, so truncation is by sorted key.
final class PropertyTruncationDeterminismTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func core(file: URL) -> BeaconstatCore {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200, data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
        let c = BeaconstatCore(store: InMemorySecureStore(),
                               clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_594_600) }),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app",
                               queueFileURL: file, reachabilityFactory: { _ in nil })
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
        return c
    }

    /// Keys that sort the same lexicographically and numerically, so the
    /// expected survivors are obvious by inspection.
    private func sixtyKeys() -> [String: String] {
        var props: [String: String] = [:]
        for i in 0..<60 { props[String(format: "k%02d", i)] = "v\(i)" }
        return props
    }

    private func survivingKeys(_ c: BeaconstatCore) -> Set<String> {
        let bodies = MockURLProtocol.capturedRequests.enumerated().compactMap { i, req in
            req.url!.path.hasSuffix("/events") ? MockURLProtocol.capturedBodies[i] : nil
        }
        for data in bodies {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = json["events"] as? [[String: Any]],
                  let event = events.first(where: { ($0["name"] as? String) == "feature_used" }),
                  let props = event["properties"] as? [String: Any] else { continue }
            return Set(props.keys.filter { $0.hasPrefix("k") })
        }
        XCTFail("no feature_used event reached the wire")
        return []
    }

    /// The review's failure: an arbitrary hash-ordered 49 of 60 survive. This
    /// pins the *specific* set, which is the only assertion a dictionary's
    /// per-process-seeded iteration order cannot satisfy by luck.
    func testTruncationKeepsTheLexicographicallyFirstFortyNineKeys() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        c.track("feature_used", properties: sixtyKeys())
        c.flush()
        let done = expectation(description: "flow"); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)

        let expected = Set((0..<49).map { String(format: "k%02d", $0) })
        XCTAssertEqual(survivingKeys(c), expected,
                       "truncation must be deterministic, not hash-ordered")
        c.shutdown()
    }

    /// And the same input truncates the same way twice — the property a host
    /// actually depends on when they look at two days of data.
    func testTruncationIsStableAcrossTwoIdenticalTracks() {
        let fileA = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        let fileB = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer {
            try? FileManager.default.removeItem(at: fileA)
            try? FileManager.default.removeItem(at: fileB)
        }

        let first = core(file: fileA)
        first.track("feature_used", properties: sixtyKeys())
        first.flush()
        let doneA = expectation(description: "a"); first.onQuiescent { doneA.fulfill() }
        wait(for: [doneA], timeout: 3)
        let a = survivingKeys(first)
        first.shutdown()

        MockURLProtocol.reset()
        let second = core(file: fileB)
        second.track("feature_used", properties: sixtyKeys())
        second.flush()
        let doneB = expectation(description: "b"); second.onQuiescent { doneB.fulfill() }
        wait(for: [doneB], timeout: 3)
        let b = survivingKeys(second)
        second.shutdown()

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 49)
    }
}
