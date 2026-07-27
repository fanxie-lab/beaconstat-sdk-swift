import XCTest
@testable import Beaconstat

/// H4 — `BeaconstatOptions` numerics were completely unvalidated.
/// `flushInterval: 0` scheduled a `DispatchSourceTimer` with `repeating: 0`,
/// measured at ~345,000 fires per second, each doing a synchronous Keychain
/// read. `batchSize: 0` flushed on every event; `batchSize > maxQueuedEvents`
/// made the size trigger unreachable; `sessionTimeout <= 0` started a new
/// session (2 Keychain writes) per event.
final class ConfigurationClampTests: XCTestCase {
    private let validKey = "bcs_pub_abcdef0123456789"
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func config(_ mutate: (inout BeaconstatOptions) -> Void) throws -> Configuration {
        var o = BeaconstatOptions()
        mutate(&o)
        return try Configuration(publicKey: validKey, hmacSecret: validHmac, options: o)
    }

    // MARK: - flushInterval

    func testFlushIntervalZeroIsClampedToTheFloor() throws {
        let c = try config { $0.flushInterval = 0 }
        XCTAssertEqual(c.options.flushInterval, BeaconstatOptions.Limits.flushInterval.lowerBound)
        XCTAssertTrue(c.clampNotices.contains { $0.contains("flushInterval") })
    }

    func testNegativeFlushIntervalIsClampedToTheFloor() throws {
        let c = try config { $0.flushInterval = -1 }
        XCTAssertEqual(c.options.flushInterval, BeaconstatOptions.Limits.flushInterval.lowerBound)
    }

    func testFlushIntervalAboveCeilingIsClamped() throws {
        let c = try config { $0.flushInterval = 10_000_000 }
        XCTAssertEqual(c.options.flushInterval, BeaconstatOptions.Limits.flushInterval.upperBound)
    }

    func testNonFiniteFlushIntervalFallsBackToTheDefault() throws {
        for bad in [TimeInterval.nan, .infinity, -.infinity] {
            let c = try config { $0.flushInterval = bad }
            XCTAssertTrue(BeaconstatOptions.Limits.flushInterval.contains(c.options.flushInterval),
                          "flushInterval \(bad) left \(c.options.flushInterval) out of range")
            XCTAssertFalse(c.clampNotices.isEmpty)
        }
    }

    // MARK: - batchSize

    func testBatchSizeZeroIsClampedToOne() throws {
        let c = try config { $0.batchSize = 0 }
        XCTAssertEqual(c.options.batchSize, 1)
        XCTAssertTrue(c.clampNotices.contains { $0.contains("batchSize") })
    }

    /// `batchSize > maxQueuedEvents` made the size trigger unreachable: eviction
    /// caps the queue at `maxQueuedEvents`, so `count >= batchSize` never held.
    func testBatchSizeAboveMaxQueuedIsClampedSoTheSizeTriggerCanFire() throws {
        let c = try config { $0.maxQueuedEvents = 10; $0.batchSize = 500 }
        XCTAssertEqual(c.options.batchSize, 10)
        XCTAssertLessThanOrEqual(c.options.batchSize, c.options.maxQueuedEvents)
    }

    /// The ceiling is computed against the *clamped* maxQueuedEvents, not the raw one.
    func testBatchSizeCeilingUsesTheClampedMaxQueuedEvents() throws {
        let c = try config { $0.maxQueuedEvents = 0; $0.batchSize = 50 }
        XCTAssertEqual(c.options.maxQueuedEvents, BeaconstatOptions.Limits.maxQueuedEvents.lowerBound)
        XCTAssertLessThanOrEqual(c.options.batchSize, c.options.maxQueuedEvents)
    }

    // MARK: - sessionTimeout

    func testSessionTimeoutZeroIsClampedToTheFloor() throws {
        let c = try config { $0.sessionTimeout = 0 }
        XCTAssertEqual(c.options.sessionTimeout, BeaconstatOptions.Limits.sessionTimeout.lowerBound)
        XCTAssertTrue(c.clampNotices.contains { $0.contains("sessionTimeout") })
    }

    func testNonFiniteSessionTimeoutFallsBackToTheDefault() throws {
        let c = try config { $0.sessionTimeout = .nan }
        XCTAssertTrue(BeaconstatOptions.Limits.sessionTimeout.contains(c.options.sessionTimeout))
    }

    // MARK: - maxQueuedEvents / maxRetries

    func testMaxQueuedEventsZeroIsClampedToTheFloor() throws {
        let c = try config { $0.maxQueuedEvents = 0 }
        XCTAssertEqual(c.options.maxQueuedEvents, BeaconstatOptions.Limits.maxQueuedEvents.lowerBound)
    }

    func testMaxQueuedEventsAboveCeilingIsClamped() throws {
        let c = try config { $0.maxQueuedEvents = 10_000_000 }
        XCTAssertEqual(c.options.maxQueuedEvents, BeaconstatOptions.Limits.maxQueuedEvents.upperBound)
    }

    func testNegativeMaxRetriesIsClampedToZero() throws {
        let c = try config { $0.maxRetries = -5 }
        XCTAssertEqual(c.options.maxRetries, 0)
    }

    func testMaxRetriesAboveCeilingIsClamped() throws {
        let c = try config { $0.maxRetries = 99 }
        XCTAssertEqual(c.options.maxRetries, BeaconstatOptions.Limits.maxRetries.upperBound)
    }

    // MARK: - the happy path must be untouched

    func testDefaultOptionsAreNeverClamped() throws {
        let c = try Configuration(publicKey: validKey, hmacSecret: validHmac, options: BeaconstatOptions())
        let d = BeaconstatOptions()
        XCTAssertEqual(c.clampNotices, [])
        XCTAssertEqual(c.options.flushInterval, d.flushInterval)
        XCTAssertEqual(c.options.batchSize, d.batchSize)
        XCTAssertEqual(c.options.sessionTimeout, d.sessionTimeout)
        XCTAssertEqual(c.options.maxQueuedEvents, d.maxQueuedEvents)
        XCTAssertEqual(c.options.maxRetries, d.maxRetries)
    }

    func testEveryDefaultIsInsideItsDocumentedRange() {
        let d = BeaconstatOptions()
        XCTAssertTrue(BeaconstatOptions.Limits.flushInterval.contains(d.flushInterval))
        XCTAssertTrue(BeaconstatOptions.Limits.sessionTimeout.contains(d.sessionTimeout))
        XCTAssertTrue(BeaconstatOptions.Limits.maxQueuedEvents.contains(d.maxQueuedEvents))
        XCTAssertTrue(BeaconstatOptions.Limits.maxRetries.contains(d.maxRetries))
        XCTAssertTrue(BeaconstatOptions.Limits.batchSize.contains(d.batchSize))
    }

    /// The clamp is worthless if the core then reads the host's raw options, and
    /// silent clamping is its own bug — assert the core logs it.
    func testCoreLogsEveryClampAtConfigure() {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { _ in .init(statusCode: 500) }
        let log = LogCollector()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let core = BeaconstatCore(store: InMemorySecureStore(),
                                  clock: SystemClock(),
                                  sessionProvider: { _ in .mocked() },
                                  bundleIdentifier: "com.example.app",
                                  queueFileURL: file,
                                  logSink: { log.append($0) })
        var o = BeaconstatOptions()
        // Explicit, not inherited from the build configuration: the logger is
        // `debugLogging || isDebugBuild`, so a test that asserts on log output
        // silently asserted nothing under `swift test -c release`.
        o.debugLogging = true
        o.flushInterval = 0
        o.batchSize = 0
        o.sessionTimeout = 0
        o.maxRetries = -1
        core.configure(publicKey: validKey, hmacSecret: validHmac, options: o,
                       environment: ["device.platform": "ios"])
        let done = expectation(description: "configured"); core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 3)

        let lines = log.lines.joined(separator: "\n")
        for field in ["flushInterval", "batchSize", "sessionTimeout", "maxRetries"] {
            XCTAssertTrue(lines.contains(field), "no clamp log line mentioned \(field):\n\(lines)")
        }
    }

    /// Non-numeric options must survive clamping untouched.
    func testClampingPreservesNonNumericOptions() throws {
        let endpoint = URL(string: "https://ingest.example.com")!
        let c = try config {
            $0.flushInterval = 0
            $0.endpoint = endpoint
            $0.testMode = .forceTest
            $0.productVersion = "4.2.0"
            $0.flushOnBackground = false
            $0.collectAccessibility = false
        }
        XCTAssertEqual(c.options.endpoint, endpoint)
        XCTAssertEqual(c.options.testMode, .forceTest)
        XCTAssertEqual(c.options.productVersion, "4.2.0")
        XCTAssertFalse(c.options.flushOnBackground)
        XCTAssertFalse(c.options.collectAccessibility)
        XCTAssertEqual(c.baseURL, endpoint)
    }
}
