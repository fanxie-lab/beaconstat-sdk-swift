import XCTest
@testable import Beaconstat

/// The public facade.
///
/// **This test executes nothing that mutates process-global state.** That is the
/// L10 fix, and it took two attempts to get right, so the reasoning is worth
/// recording.
///
/// The original version drove `BeaconstatCore.shared`: the host machine's real
/// Keychain, real `URLSession`, real `NWPathMonitor`, real `NotificationCenter`
/// observers, real 30 s flush timer, the real default queue path (it left
/// `~/Library/Application Support/Beaconstat/queue.json` on the reviewer's
/// machine), and the process-global opt-out flag — which a failure between
/// `optOut()` and `optIn()` would leave engaged for every test that followed.
///
/// The obvious repair — snapshot those files in `setUp`, `shutdown()` and
/// restore them in `tearDown` — **does not work**, and it is worth saying why:
/// `configure()` starts a handshake, and that request's completion re-hops onto
/// the core's serial queue whenever the network gets round to failing. It can
/// therefore write `queue.json` and `identity.json` *after* teardown has
/// restored them. Draining with `onQuiescent` narrows the window but cannot
/// close it, because the write that matters happens on a queue block scheduled
/// by a completion that had not arrived yet. Measured: the restore ran, and both
/// files were back on disk a few milliseconds later.
///
/// So the runtime exercise moved to `RealDependencySmokeTests`, which drives a
/// **directly constructed** core with every real collaborator — real Keychain
/// store, real `TelemetrySession`, real `NWPathReachability`, real
/// `LifecycleObserver`, real background assertion — and only the two file paths
/// and the Keychain service redirected. That covers strictly more of the
/// default-argument wiring than the old smoke test did, with nothing global left
/// behind.
///
/// What stays here is what genuinely needs the facade: the compile-time witness
/// that the documented call sites still compile from (and off) the main actor,
/// and the read-only assertions. Reading `Beaconstat.isOptedOut` touches
/// `BeaconstatCore.shared`, but construction only *reads* secure storage —
/// `FileSecureStore` creates nothing until something is written — so it leaves
/// no artefact.
///
/// `@MainActor` because `Beaconstat.configure` is (M1).
@MainActor
final class PublicAPISmokeTests: XCTestCase {
    /// The public getter must answer without configuring, without blocking, and
    /// consistently with the core it forwards to.
    func testIsOptedOutIsReadableBeforeConfigureAndForwardsToTheCore() {
        XCTAssertEqual(Beaconstat.isOptedOut, BeaconstatCore.shared.isOptedOut)
    }

    /// The default file locations must sit under Application Support (or the
    /// temporary directory when that cannot be resolved) and must be distinct —
    /// the identity mirror sharing a path with the queue would destroy both.
    func testDefaultOnDiskLocationsAreDistinctAndNamespaced() {
        let queue = BeaconstatCore.defaultQueueFileURL()
        let identity = BeaconstatCore.defaultIdentityFileURL()
        XCTAssertNotEqual(queue, identity)
        XCTAssertEqual(queue.lastPathComponent, "queue.json")
        XCTAssertEqual(identity.lastPathComponent, "identity.json")
        XCTAssertEqual(queue.deletingLastPathComponent().lastPathComponent, "Beaconstat")
        XCTAssertEqual(identity.deletingLastPathComponent(), queue.deletingLastPathComponent())
    }

    /// Resolving the default locations must not create anything. They are
    /// computed while `BeaconstatCore.shared` is being built, on the main thread
    /// during app launch, and creating a directory there is synchronous disk I/O
    /// before first frame (M6).
    func testResolvingTheDefaultLocationsCreatesNothing() {
        let directory = BeaconstatCore.defaultQueueFileURL().deletingLastPathComponent()
        let existedBefore = FileManager.default.fileExists(atPath: directory.path)
        _ = BeaconstatCore.defaultQueueFileURL()
        _ = BeaconstatCore.defaultIdentityFileURL()
        XCTAssertEqual(FileManager.default.fileExists(atPath: directory.path), existedBefore)
    }
}

/// Compile-time witness for the whole public surface, from a main-actor context.
///
/// Never executed — it exists so that a source-breaking change to any public
/// signature fails the build rather than silently changing what hosts must
/// write. It costs no global state, no disk, no network and no teardown, and it
/// covers entry points a runtime test would have to be careful about calling.
@MainActor
private func documentedCallSitesCompile() {
    Beaconstat.configure(publicKey: "bcs_pub_x", hmacSecret: String(repeating: "a", count: 64))

    var options = BeaconstatOptions()
    options.testMode = .forceTest
    options.batchSize = 10
    options.flushInterval = 60
    options.flushOnBackground = true
    options.sessionTimeout = 300
    options.maxQueuedEvents = 500
    options.maxRetries = 3
    options.debugLogging = true
    options.collectAccessibility = true
    options.endpoint = URL(string: "https://ingest.example.com")
    options.keychainAccessGroup = "ABCDE12345.com.example.shared"
    options.productVersion = "1.2.3"
    options.routeTestFlightToTest = true
    options.sendEventIds = true
    options.allowInsecureEndpoint = false
    Beaconstat.configure(publicKey: "bcs_pub_x",
                         hmacSecret: String(repeating: "a", count: 64),
                         options: options)

    // The memberwise initialiser, which is what the migration guide documents.
    _ = BeaconstatOptions(testMode: .automatic, batchSize: 50, flushInterval: 60,
                          flushOnBackground: true, sessionTimeout: 300,
                          maxQueuedEvents: 500, maxRetries: 3, debugLogging: false,
                          collectAccessibility: false, endpoint: nil,
                          keychainAccessGroup: nil, productVersion: nil,
                          routeTestFlightToTest: false, sendEventIds: false,
                          allowInsecureEndpoint: false)

    Beaconstat.track("feature_used")
    Beaconstat.track("feature_used", properties: ["feature": "export"])
    Beaconstat.flush()
    Beaconstat.shutdown()
    Beaconstat.optOut()
    Beaconstat.optIn()
    _ = Beaconstat.isOptedOut
    Beaconstat.opened(from: URL(string: "myapp://home")!)
    Beaconstat.openedFromActivity(webpageURL: nil)
    Beaconstat.openedFromShortcut(type: "com.example.newItem")
    Beaconstat.openedFromWidget(kind: nil, family: nil)
    Beaconstat.pushReceived(category: nil, wasSilent: false)
    Beaconstat.pushOpened(category: nil, actionId: nil)
}

/// Off the main actor, every entry point *except* `configure` must still be
/// callable — a push extension reporting `pushReceived` has no main actor, and a
/// background task calling `track` must not have to hop. `configure` is
/// `@MainActor` (M1) and calling it from here would not compile, which is the
/// migration's single hardest break, so pin both halves.
private func nonIsolatedCallSitesCompile() {
    Beaconstat.track("feature_used", properties: ["feature": "export"])
    Beaconstat.flush()
    Beaconstat.optOut()
    Beaconstat.optIn()
    _ = Beaconstat.isOptedOut
    Beaconstat.shutdown()
    Beaconstat.opened(from: URL(string: "myapp://home")!)
    Beaconstat.openedFromActivity(webpageURL: nil)
    Beaconstat.openedFromShortcut(type: "com.example.newItem")
    Beaconstat.openedFromWidget(kind: nil, family: nil)
    Beaconstat.pushReceived(category: "MESSAGE", wasSilent: true)
    Beaconstat.pushOpened(category: "MESSAGE", actionId: "REPLY")
}
