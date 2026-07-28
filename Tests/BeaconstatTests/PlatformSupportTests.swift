import XCTest
@testable import Beaconstat

/// L9 — `Package.swift` declared only `.iOS(.v15)` / `.macOS(.v12)` while the
/// README and CHANGELOG advertised tvOS, watchOS and visionOS. Undeclared
/// platforms inherit the toolchain's *default* deployment target instead of the
/// advertised minimum, and none of them was in CI.
///
/// Two things that cost real behaviour came out of that:
///
/// - watchOS shipped 1.0.0 with **no lifecycle events at all** — the UIKit
///   branch excluded it and the AppKit branch didn't match, so
///   `app_backgrounded` and foreground session resume silently never fired.
///   Wave 3 wired up WatchKit; declaring the platform is what stops it
///   regressing.
/// - visionOS **did not compile**: `UIScreen` is `API_UNAVAILABLE(visionos)` and
///   `screenMetrics()` referenced it unconditionally under
///   `canImport(UIKit) && !os(watchOS)`. Nobody found it because nothing ever
///   built for visionOS. The review recorded visionOS as "could not verify".
final class PlatformSupportTests: XCTestCase {
    /// The assertion watchOS failed. Every platform the package declares must
    /// observe *something*, or that platform silently stops reporting sessions.
    ///
    /// It runs on whichever platform the suite is compiled for, so CI's
    /// per-platform matrix is what gives it teeth — on one machine it only ever
    /// proved the macOS mapping.
    func testThisPlatformObservesBothABackgroundAndAForegroundTransition() {
        let transitions = LifecycleObserver.transitions()
        XCTAssertFalse(transitions.isEmpty,
                       "\(EnvironmentCollector.platform) observes no lifecycle notifications at all")
        XCTAssertTrue(transitions.contains { $0.transition == .background },
                      "no background transition on \(EnvironmentCollector.platform)")
        XCTAssertTrue(transitions.contains { $0.transition == .foreground },
                      "no foreground transition on \(EnvironmentCollector.platform)")
    }

    /// A notification must map to exactly one transition, or one OS signal would
    /// both emit `app_backgrounded` and flush twice.
    func testEachObservedNotificationMapsToExactlyOneTransition() {
        let names = LifecycleObserver.transitions().map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "a notification is observed twice: \(names)")
    }

    /// The environment snapshot has to be collectable on every platform without
    /// trapping — this is the call that `configure()` makes at launch.
    @MainActor
    func testTheEnvironmentSnapshotIsCollectableOnThisPlatform() {
        let collector = EnvironmentCollector(sdkVersion: BeaconstatVersion.current,
                                             appVersion: "1.0.0", appBuild: "1",
                                             collectAccessibility: true)
        let environment = collector.collect()
        XCTAssertFalse(environment.isEmpty)
        XCTAssertEqual(environment["sdk.version"], BeaconstatVersion.current)
        XCTAssertNotNil(environment["device.platform"])
    }

    /// visionOS has no screen — it has volumes and windows the user resizes and
    /// moves in space — so `device.screen_*` would be a fabrication. Every other
    /// platform that has a screen must still report one.
    func testScreenMetricsArePresentExactlyWhereThePlatformHasAScreen() {
        let metrics = EnvironmentCollector.screenMetrics()
        #if os(visionOS) || os(watchOS)
        XCTAssertNil(metrics, "\(EnvironmentCollector.platform) has no single screen to report")
        #else
        let unwrapped = try? XCTUnwrap(metrics,
                                       "\(EnvironmentCollector.platform) should report screen metrics")
        XCTAssertGreaterThan(unwrapped?.width ?? 0, 0)
        XCTAssertGreaterThan(unwrapped?.height ?? 0, 0)
        XCTAssertGreaterThan(unwrapped?.scale ?? 0, 0)
        #endif
    }

    /// `run_context.target_environment` must be a known token everywhere, since
    /// it is a reserved dimension the dashboard groups on.
    func testTargetEnvironmentIsAKnownToken() {
        let collector = EnvironmentCollector(sdkVersion: BeaconstatVersion.current,
                                             appVersion: nil, appBuild: nil,
                                             collectAccessibility: false)
        let value = collector.collectDeferrable()["run_context.target_environment"]
        XCTAssertNotNil(value)
        // Every token `EnvironmentCollector.targetEnvironment()` can return.
        // The old list had two bugs that only a non-macOS destination could
        // expose: it omitted `simulator` entirely, and spelled Catalyst
        // `catalyst` where the collector emits `mac_catalyst` — so the guard on
        // a reserved dashboard dimension would have failed on the very builds
        // it exists to protect.
        XCTAssertTrue(["native", "mac_catalyst", "simulator", "ios_on_mac"].contains(value ?? ""),
                      "\(value ?? "nil")")
    }
}
