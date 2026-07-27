import XCTest
@testable import Beaconstat

/// The default-argument wiring, exercised for real.
///
/// Every other test in the suite injects a mock `URLSession`, a
/// `reachabilityFactory` that returns `nil`, and an `InMemorySecureStore`. That
/// is right for testing behaviour, but it means the collaborators a shipping app
/// actually gets — `TelemetrySession.make()`, `NWPathReachability`,
/// `LifecycleObserver()`, `BackgroundActivityFactory.make()`,
/// `LayeredSecureStore(primary: KeychainSecureStore(), mirror: FileSecureStore(…))`
/// — were only ever constructed by `PublicAPISmokeTests`, which drove
/// `BeaconstatCore.shared` and leaked its state into the rest of the run (L10).
///
/// This does the same job with the same real collaborators, but on a core the
/// test owns: the two file paths point at the temporary directory, the Keychain
/// service is namespaced so it cannot collide with a real install's items, and
/// nothing here can be observed by another test.
///
/// The endpoint is `https://sdk-test.invalid` — `.invalid` is reserved by
/// RFC 2606 and never resolves, so no packet leaves the machine, but the real
/// `URLSession` configuration and the real DNS path are still exercised.
final class RealDependencySmokeTests: XCTestCase {
    private let validHmac = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /// A `LayeredSecureStore` built exactly the way `BeaconstatCore.init`'s
    /// default argument builds it, except for the service name and mirror path.
    ///
    /// The Keychain tier is genuinely consulted. In an unsigned SwiftPM bundle
    /// its writes fail, which is the point: this is the only test that runs the
    /// real degraded-storage path end to end rather than simulating it with a
    /// stub.
    private func realStore() -> LayeredSecureStore {
        LayeredSecureStore(
            primary: KeychainSecureStore(service: "com.beaconstat.sdk.tests.\(UUID().uuidString)"),
            mirror: FileSecureStore(fileURL: makeTemporaryQueueFile("identity")))
    }

    private func realCore() -> BeaconstatCore {
        // Only `store` and `queueFileURL` are supplied. `sessionProvider`,
        // `reachabilityFactory`, `lifecycleObserver`, `backgroundActivity`,
        // `payloadEncoder` and `clock` all take their production defaults.
        BeaconstatCore(store: realStore(), queueFileURL: makeTemporaryQueueFile())
    }

    private func options() -> BeaconstatOptions {
        var o = BeaconstatOptions()
        o.endpoint = URL(string: "https://sdk-test.invalid")
        o.flushInterval = 3600
        return o
    }

    private func drain(_ c: BeaconstatCore, _ label: String = "flow") {
        let done = expectation(description: label)
        c.onQuiescent { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    /// The whole public surface, driven through the core, against the real
    /// collaborators. Nothing here asserts on the wire — nothing can reach it.
    /// The assertion is that none of it crashes, deadlocks, or wedges the queue.
    func testEveryEntryPointRunsAgainstTheRealCollaborators() {
        let core = realCore()
        core.configure(publicKey: "bcs_pub_test", hmacSecret: validHmac,
                       options: options(), environment: ["device.platform": "ios"])
        // Reconfigure must be safe: it invalidates the previous URLSession
        // rather than stranding it, and applies the new options in place (M7).
        core.configure(publicKey: "bcs_pub_test", hmacSecret: validHmac,
                       options: options(), environment: ["device.platform": "ios"])
        core.track("feature_used", properties: ["feature": "export"])
        core.track("settings_opened", properties: [:])
        core.trackOpenURL(URL(string: "myapp://home/secret?token=x")!)
        core.trackOpenActivity(URL(string: "https://example.com/deep"))
        core.trackShortcut("com.example.newItem")
        core.trackWidget(kind: "TodayWidget", family: "systemSmall")
        core.trackPushReceived(category: "MESSAGE", wasSilent: true)
        core.trackPushOpened(category: "MESSAGE", actionId: "REPLY")
        core.flush()
        drain(core, "entry points")

        core.shutdown()
        drain(core, "shut down")
    }

    /// The kill switch against real timers, a real path monitor and real
    /// `NotificationCenter` observers — the resources M14 was about. On a
    /// process-global singleton a failure here used to leave the SDK opted out
    /// for the rest of the run; on a core the test owns, it cannot.
    func testConsentToggleRunsAgainstTheRealCollaborators() {
        let core = realCore()
        core.configure(publicKey: "bcs_pub_test", hmacSecret: validHmac,
                       options: options(), environment: ["device.platform": "ios"])
        drain(core, "configured")

        core.optOut()
        XCTAssertTrue(core.isOptedOut, "the getter must agree with the call that just returned (M4)")
        drain(core, "opted out")

        core.optIn()
        XCTAssertFalse(core.isOptedOut)
        drain(core, "opted in")

        core.shutdown()
        drain(core, "shut down")
    }

    /// `shutdown()` must be idempotent, and `configure()` afterwards must bring
    /// the SDK back — the documented contract, against the real `URLSession`
    /// that `finishTasksAndInvalidate()` actually operates on.
    func testShutdownIsIdempotentAndConfigureRevivesTheSDK() {
        let core = realCore()
        core.configure(publicKey: "bcs_pub_test", hmacSecret: validHmac,
                       options: options(), environment: ["device.platform": "ios"])
        drain(core, "configured")
        core.shutdown()
        core.shutdown()
        core.shutdown()
        drain(core, "shut down thrice")

        core.configure(publicKey: "bcs_pub_test", hmacSecret: validHmac,
                       options: options(), environment: ["device.platform": "ios"])
        core.track("after_revival", properties: [:])
        drain(core, "revived")
        core.shutdown()
        drain(core, "final")
    }

    /// A cleartext endpoint must be refused even here, where every other
    /// dependency is real (M11).
    func testRealConfigurationStillRefusesACleartextEndpoint() {
        let core = realCore()
        var o = options()
        o.endpoint = URL(string: "http://sdk-test.invalid")
        let log = LogCollector()
        o.debugLogging = true
        let logged = BeaconstatCore(store: realStore(), queueFileURL: makeTemporaryQueueFile(),
                                    logSink: log.append)
        logged.configure(publicKey: "bcs_pub_test", hmacSecret: validHmac,
                         options: o, environment: ["device.platform": "ios"])
        drain(logged, "rejected")
        XCTAssertTrue(log.contains("insecureEndpoint"), "\(log.lines)")
        logged.shutdown()
        drain(logged, "shut down")
        core.shutdown()
    }
}
