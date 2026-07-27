import XCTest
@testable import Beaconstat

/// L6 — the default log sink is now `os.Logger`, and messages are interpolated
/// `.public` because `os_log` otherwise redacts every dynamic string to
/// `<private>` and the channel is useless.
///
/// That choice is only sound while an invariant holds: **no property value, no
/// environment value, no credential and no site token is ever handed to the
/// logger.** The review checked all fourteen call sites by hand and confirmed
/// it; Waves 2 and 3 then added a dozen more. Hand-checking does not survive
/// another wave, so this pins it by driving the SDK hard with poisoned values
/// and asserting none of them come out.
///
/// Property *keys* and event *names* are deliberately allowed: they are
/// developer-authored identifiers that already travel on the wire, and without
/// them "dropping invalid property key" tells you nothing.
final class LoggerPrivacyTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    /// Distinctive, non-hex, and impossible to produce by accident.
    private let secretValue = "SUPERSECRETVALUEZZYZX"
    private let hmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let publicKey = "bcs_pub_abcdef0123456789"
    private let siteToken = "bcs_tok_SECRETTOKENZZYZX"

    private func handshake202() {
        MockURLProtocol.handler = { [siteToken] req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200,
                        data: Data(#"{"siteToken":"\#(siteToken)","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 202)
        }
    }

    /// Every path that logs, exercised in one run: valid events, invalid names,
    /// invalid keys, oversized values, over-cap property counts, unsafe reserved
    /// values, deep links, push, clamped options, a rejected batch, and a
    /// degraded store.
    func testNoSecretValueEverReachesTheLogSink() {
        handshake202()
        let log = LogCollector()
        let core = BeaconstatCore(store: InMemorySecureStore(),
                                  clock: SystemClock(dateProvider: {
                                      Date(timeIntervalSince1970: 1_776_580_200)
                                  }),
                                  sessionProvider: { _ in .mocked() },
                                  bundleIdentifier: "com.example.app",
                                  queueFileURL: makeTemporaryQueueFile(),
                                  reachabilityFactory: { _ in nil },
                                  logSink: log.append)
        var options = BeaconstatOptions()
        options.debugLogging = true          // force the sink on in every configuration
        options.flushInterval = 0            // triggers a clamp notice
        options.batchSize = 0                // ditto
        options.endpoint = URL(string: "https://ingest.example.com")
        core.configure(publicKey: publicKey, hmacSecret: hmac, options: options,
                       environment: ["device.platform": "ios", "app.version": secretValue])

        // Ordinary event with a secret value.
        core.track("feature_used", properties: ["feature": secretValue])
        // Oversized value — logs "dropping oversized property value for key".
        core.track("feature_used", properties: ["big": String(repeating: secretValue, count: 200)])
        // Invalid key — logs "dropping invalid property key".
        core.track("feature_used", properties: ["Invalid Key": secretValue])
        // Over the 49-key cap — logs "property count limit reached".
        var many: [String: String] = [:]
        for i in 0..<60 { many["k\(i)"] = secretValue }
        core.track("feature_used", properties: many)
        // Reserved dimensions carrying a payload — logs "dropping unsafe value
        // for reserved key" (M2).
        core.trackShortcut("openChat:\(secretValue)@example.com")
        core.trackWidget(kind: secretValue + "/" + secretValue, family: secretValue)
        core.trackPushReceived(category: "cat:\(secretValue)", wasSilent: true)
        core.trackPushOpened(category: nil, actionId: "act/\(secretValue)")
        core.trackOpenURL(URL(string: "myapp://host/\(secretValue)?q=\(secretValue)")!)
        core.flush()

        let done = expectation(description: "drained"); core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
        core.shutdown()

        let lines = log.joined
        XCTAssertFalse(lines.isEmpty, "the sink captured nothing, so this asserts nothing")
        XCTAssertFalse(lines.contains(secretValue),
                       "a host-supplied VALUE reached the logger:\n\(lines)")
        XCTAssertFalse(lines.contains(hmac), "the HMAC secret reached the logger:\n\(lines)")
        XCTAssertFalse(lines.contains(siteToken), "the site token reached the logger:\n\(lines)")
        XCTAssertFalse(lines.contains(publicKey), "the public key reached the logger:\n\(lines)")
    }

    /// A rejected batch and a failing store are the noisiest error paths, and
    /// the most tempting places to dump context. They must stay clean too.
    func testErrorPathsDoNotLogCredentialsOrValues() {
        MockURLProtocol.handler = { [siteToken] req in
            req.url!.path.hasSuffix("/handshake")
                ? .init(statusCode: 200,
                        data: Data(#"{"siteToken":"\#(siteToken)","serverTime":"2026-04-19T10:30:00.000Z"}"#.utf8))
                : .init(statusCode: 403) // poison-drop, logs
        }
        let log = LogCollector()
        let core = BeaconstatCore(store: NonDurableSecureStore(),
                                  clock: SystemClock(),
                                  sessionProvider: { _ in .mocked() },
                                  bundleIdentifier: "com.example.app",
                                  queueFileURL: makeTemporaryQueueFile(),
                                  reachabilityFactory: { _ in nil },
                                  logSink: log.append)
        var options = BeaconstatOptions()
        options.debugLogging = true
        options.batchSize = 1
        core.configure(publicKey: publicKey, hmacSecret: hmac, options: options,
                       environment: ["device.platform": "ios"])
        core.track("feature_used", properties: ["feature": secretValue])
        let done = expectation(description: "drained"); core.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 5)
        core.shutdown()

        let lines = log.joined
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(lines.contains(secretValue), lines)
        XCTAssertFalse(lines.contains(hmac), lines)
        XCTAssertFalse(lines.contains(siteToken), lines)
    }

    /// The other half of L6: a library must not write to a host's console
    /// unless asked. With `debugLogging` off in a Release build, the sink is
    /// never called at all — not merely filtered downstream.
    func testTheSinkIsNotEvenInvokedWhenLoggingIsOff() {
        let collector = LogCollector()
        let logger = Logger(enabled: false, sink: collector.append)
        logger.debug("this must not be evaluated: \(self.expensive(collector))")
        XCTAssertTrue(collector.lines.isEmpty)
    }

    /// Records that it ran, so the `@autoclosure` short-circuit is observable
    /// rather than assumed.
    private func expensive(_ collector: LogCollector) -> String {
        collector.append("EVALUATED")
        return "EVALUATED"
    }

    func testSubsystemAndCategoryAreNamespaced() {
        XCTAssertEqual(Logger.subsystem, "com.beaconstat.sdk")
        XCTAssertFalse(Logger.category.isEmpty)
    }
}
