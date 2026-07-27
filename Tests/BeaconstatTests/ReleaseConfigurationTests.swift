import XCTest
@testable import Beaconstat

/// Test gap 6 — Release-configuration behaviour was entirely untested.
///
/// `swift test -c release` did not compile: `onQuiescent` was `#if DEBUG`, so
/// forty-odd call sites failed with "value of type 'BeaconstatCore' has no
/// member 'onQuiescent'". CI ran Debug only. Which meant the two behaviours that
/// exist **solely** in Release — `.automatic` routing sending batches to
/// `/v1/events` instead of `/v1/debug/events`, and a 4-hour default
/// `flushInterval` — had never been executed by a test on any machine.
///
/// These assertions are deliberately written to hold in *both* configurations,
/// branching where the expected value genuinely differs. Run under
/// `swift test` they pin the Debug contract; run under `swift test -c release`
/// they pin the Release one, and that second run is what CI now does.
final class ReleaseConfigurationTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func tempQueue() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
    }

    private func handshake202() {
        MockURLProtocol.handler = { req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200,
                        data: Data(#"{"siteToken":"bcs_tok_z","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
    }

    private func core(file: URL) -> BeaconstatCore {
        BeaconstatCore(store: InMemorySecureStore(),
                       clock: SystemClock(dateProvider: { Date(timeIntervalSince1970: 1_776_580_200) }),
                       sessionProvider: { _ in .mocked() },
                       bundleIdentifier: "com.example.app",
                       queueFileURL: file,
                       reachabilityFactory: { _ in nil })
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow") {
        let done = expectation(description: label); c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: - The seam itself

    /// The regression guard for the whole gap: if anyone puts `onQuiescent` back
    /// behind `#if DEBUG`, this file stops compiling in Release and CI's
    /// `swift test -c release` job goes red immediately.
    func testTheQuiescenceSeamIsAvailableInEveryConfiguration() {
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        drain(c, "seam available")
        c.shutdown()
    }

    // MARK: - Routing

    /// `.automatic` routes on the *SDK's* build configuration, not the host's
    /// mood. Debug/simulator → the debug pipeline; a shipping Release build →
    /// production ingest. The second half had never run.
    func testAutomaticRoutingFollowsTheBuildConfiguration() {
        handshake202()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        let c = core(file: file)
        var o = BeaconstatOptions(); o.flushInterval = 3600
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
        drain(c, "launch")

        let paths = MockURLProtocol.requests(forPathSuffix: "/events").map { $0.url!.path }
        XCTAssertFalse(paths.isEmpty, "nothing was sent, so routing was not exercised")
        #if DEBUG
        XCTAssertTrue(paths.allSatisfy { $0 == "/v1/debug/events" }, "\(paths)")
        #else
        XCTAssertTrue(paths.allSatisfy { $0 == "/v1/events" },
                      "a Release build must send to production ingest, not the debug pipeline: \(paths)")
        #endif
        c.shutdown()
    }

    /// `.forceTest` / `.forceProduction` must override the configuration in both
    /// directions — otherwise a Release build could never be pointed at the debug
    /// pipeline for a staging soak.
    func testForcedRoutingOverridesTheBuildConfiguration() {
        for (mode, expected) in [(TestMode.forceTest, "/v1/debug/events"),
                                 (TestMode.forceProduction, "/v1/events")] {
            MockURLProtocol.reset()
            handshake202()
            let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
            let c = core(file: file)
            var o = BeaconstatOptions(); o.flushInterval = 3600; o.testMode = mode
            c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                        options: o, environment: ["device.platform": "ios"])
            drain(c, "launch \(mode)")
            let paths = MockURLProtocol.requests(forPathSuffix: "/events").map { $0.url!.path }
            XCTAssertFalse(paths.isEmpty)
            XCTAssertTrue(paths.allSatisfy { $0 == expected }, "\(mode) → \(paths)")
            c.shutdown()
        }
    }

    // MARK: - Cadence

    /// M9's "retries exhausted" round exists precisely because the Release
    /// `flushInterval` is four hours. Pin the relationship rather than the
    /// number: the exhausted-round delay must be far shorter than the periodic
    /// timer, or a failed queue sits for four hours while the cap evicts under it.
    func testTheExhaustedRetryRoundIsMuchSoonerThanTheDefaultPeriodicFlush() {
        let delay = RetryPolicy.exhaustedRoundDelay(cappedBy: BeaconstatOptions.defaultFlushInterval)
        XCTAssertLessThanOrEqual(delay, BeaconstatOptions.defaultFlushInterval)
        #if !DEBUG
        XCTAssertEqual(BeaconstatOptions.defaultFlushInterval, 14_400)
        XCTAssertLessThan(delay, 600,
                          "in Release the periodic flush is 4 hours away; the retry round has to "
                          + "come back in minutes, not inherit that")
        #endif
    }

    /// The default cadence must be inside the range `Configuration` clamps to,
    /// in whichever configuration — a default that gets clamped would log a
    /// spurious notice on every launch.
    func testTheDefaultFlushIntervalIsNotItselfClamped() throws {
        let config = try Configuration(publicKey: "bcs_pub_abcdef0123456789",
                                       hmacSecret: validHmac,
                                       options: BeaconstatOptions())
        XCTAssertEqual(config.options.flushInterval, BeaconstatOptions.defaultFlushInterval)
        XCTAssertTrue(config.clampNotices.isEmpty, "\(config.clampNotices)")
    }

    // MARK: - Logging

    /// In Release the logger is silent unless the host asks for it. In Debug it
    /// is on. Both halves matter: a library that prints on a customer's console
    /// by default is a bug, and one that cannot be turned on is undebuggable.
    func testDebugLoggingDefaultsOffInReleaseAndOnInDebug() {
        let collector = LogCollector()
        let file = tempQueue(); defer { try? FileManager.default.removeItem(at: file) }
        handshake202()
        let c = BeaconstatCore(store: InMemorySecureStore(),
                               clock: SystemClock(),
                               sessionProvider: { _ in .mocked() },
                               bundleIdentifier: "com.example.app",
                               queueFileURL: file,
                               reachabilityFactory: { _ in nil },
                               logSink: collector.append)
        var o = BeaconstatOptions(); o.flushInterval = 0 // guarantees a clamp notice to log
        c.configure(publicKey: "bcs_pub_abcdef0123456789", hmacSecret: validHmac,
                    options: o, environment: ["device.platform": "ios"])
        drain(c, "configured")
        #if DEBUG
        XCTAssertTrue(collector.contains("flushInterval"), "\(collector.lines)")
        #else
        XCTAssertTrue(collector.lines.isEmpty,
                      "a Release build must not log unless debugLogging is set: \(collector.lines)")
        #endif
        c.shutdown()
    }
}
