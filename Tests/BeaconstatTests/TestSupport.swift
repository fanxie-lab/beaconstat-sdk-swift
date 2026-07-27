import Foundation
import XCTest
@testable import Beaconstat

// MARK: - Secure-store doubles
//
// Hoisted out of `OptOutFlagTests`, where they were declared as file-scoped
// helpers even though they answer questions — "did the SDK go back to storage
// for this?" and "what does a caller observe while the serial queue is parked
// mid-write?" — that arise all over the suite.

/// Counts reads and writes per key, so a test can assert the SDK is not going
/// back to secure storage for a value it already knows (M5).
final class CountingSecureStore: SecureStore, @unchecked Sendable {
    private let inner = InMemorySecureStore()
    private let lock = NSLock()
    private var readCounts: [SecureStoreKey: Int] = [:]
    private var writeCounts: [SecureStoreKey: Int] = [:]

    func reads(of key: SecureStoreKey) -> Int {
        lock.lock(); defer { lock.unlock() }
        return readCounts[key] ?? 0
    }

    func writes(of key: SecureStoreKey) -> Int {
        lock.lock(); defer { lock.unlock() }
        return writeCounts[key] ?? 0
    }

    func resetCounts() {
        lock.lock(); defer { lock.unlock() }
        readCounts = [:]; writeCounts = [:]
    }

    func string(forKey key: SecureStoreKey) -> String? {
        lock.lock(); readCounts[key, default: 0] += 1; lock.unlock()
        return inner.string(forKey: key)
    }

    @discardableResult
    func set(_ value: String?, forKey key: SecureStoreKey) -> Bool {
        lock.lock(); writeCounts[key, default: 0] += 1; lock.unlock()
        return inner.set(value, forKey: key)
    }
}

/// Parks the first write of a chosen key until released, so a test can hold the
/// core's serial queue in a known place instead of racing it.
final class GatedSecureStore: SecureStore, @unchecked Sendable {
    private let inner = InMemorySecureStore()
    private let gatedKey: SecureStoreKey
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false

    init(gating key: SecureStoreKey) { self.gatedKey = key }

    func arm() { lock.lock(); armed = true; lock.unlock() }

    /// Blocks until the core's queue is parked inside the gated write.
    func waitUntilEntered() { entered.wait() }

    func releaseGate() { release.signal() }

    func string(forKey key: SecureStoreKey) -> String? { inner.string(forKey: key) }

    @discardableResult
    func set(_ value: String?, forKey key: SecureStoreKey) -> Bool {
        lock.lock()
        let shouldGate = armed && key == gatedKey
        if shouldGate { armed = false }
        lock.unlock()
        if shouldGate {
            entered.signal()
            release.wait()
        }
        return inner.set(value, forKey: key)
    }
}

// MARK: - Reading the wire

/// A decoded `/v1/events` request body.
///
/// Every wire assertion in the suite used to be `body.contains("…")` on the raw
/// JSON string. That is how test gap 10 happened: `BeaconstatCoreOpenURLTests`
/// asserted `XCTAssertFalse(body.contains("abc123"))` to prove a query parameter
/// never reaches the wire — but `abc123` is pure hex, and every body carries a
/// random session-id UUID, so roughly once in a million runs the assertion fails
/// for a reason that has nothing to do with deep-link sanitisation. The team had
/// already hit that class of failure and documented it four lines below, then
/// left this instance in.
///
/// Decoding instead makes "this value is not on the wire" mean *this property
/// does not hold this value*, which is both what the test means and immune to
/// coincidence.
struct SentBatch {
    struct SentEvent {
        let name: String
        let time: String
        let properties: [String: String]
        let id: String?

        subscript(_ key: String) -> String? { properties[key] }

        /// Everything except the session id, which is a fresh UUID per run and
        /// so cannot be compared literally.
        ///
        /// Asserting `propertiesExcludingSessionId == [...]` is the *complete*
        /// statement a sanitisation test wants: these keys, these values, and
        /// nothing else. It is also the only formulation immune to coincidence
        /// in both directions — a substring scan over the remaining values still
        /// trips over the session UUID for any hex-ish marker (`"42"` occurs in
        /// a random UUID about half the time), and a substring scan over the raw
        /// body can pass falsely when the leaked text hides inside a key.
        var propertiesExcludingSessionId: [String: String] {
            properties.filter { $0.key != "_bcs.session.id" }
        }
    }

    let productVersion: String
    let environment: [String: String]
    let events: [SentEvent]

    init?(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let productVersion = root["productVersion"] as? String,
              let rawEvents = root["events"] as? [[String: Any]] else { return nil }
        self.productVersion = productVersion
        self.environment = (root["environment"] as? [String: String]) ?? [:]
        self.events = rawEvents.compactMap { raw in
            guard let name = raw["name"] as? String, let time = raw["time"] as? String else {
                return nil
            }
            return SentEvent(name: name, time: time,
                             properties: (raw["properties"] as? [String: String]) ?? [:],
                             id: raw["id"] as? String)
        }
    }

    /// Every batch the mock captured, in order.
    static func all() -> [SentBatch] {
        MockURLProtocol.captured
            .filter { $0.request.url?.path.hasSuffix("/events") ?? false }
            .compactMap { SentBatch($0.body) }
    }

    /// Every event across every captured batch, in order.
    static func allEvents() -> [SentEvent] { all().flatMap(\.events) }

    /// The first event with this name across every captured batch.
    static func firstEvent(named name: String) -> SentEvent? {
        allEvents().first { $0.name == name }
    }

    /// Every distinct property *value* on the wire, across every event.
    ///
    /// The right way to say "this string never reached the server": compare
    /// against actual values rather than searching the serialised bytes, so a
    /// UUID that happens to contain the needle cannot produce a false failure —
    /// nor, more importantly, can a needle hidden inside a *key* produce a false
    /// pass.
    static func allPropertyValues() -> Set<String> {
        Set(allEvents().flatMap(\.properties.values))
    }
}

// MARK: - XCTest conveniences

extension XCTestCase {
    /// A queue file under the temporary directory, removed when the test ends.
    ///
    /// `addTeardownBlock` rather than `defer` so it cannot be forgotten — which
    /// is exactly what happened in `BeaconstatCoreAppUpdatedTests.run()`, the
    /// one helper in the suite that created a temp queue file per invocation and
    /// never deleted it (test gap 11).
    func makeTemporaryQueueFile(_ prefix: String = "q") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
