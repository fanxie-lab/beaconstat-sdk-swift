import XCTest
@testable import Beaconstat

/// `@MainActor` because `collect()` is (M1) — it reads `UIScreen.main`,
/// `UITraitCollection.current` and the `UIAccessibility` flags.
///
/// ## These used to assume they were running on macOS
///
/// Six assertions in this file hard-coded the host's platform — `device.platform
/// == "macos"`, `device.os_name == "macOS"`, no orientation, `target_environment
/// == "native"`, no `bold_text`. That was true for `swift test`, and false on
/// every destination CI's `platforms` job runs the suite against, so those legs
/// were red for a reason that had nothing to do with the code under test.
///
/// They are now expressed per platform. The point of the file is that the
/// collector reports the *right* value everywhere, not that it reports the
/// macOS one — and the expectations are written as literals per `#if` branch
/// rather than derived from `EnvironmentCollector`'s own constants, which would
/// only assert that the code equals itself.
@MainActor
final class EnvironmentCollectorTests: XCTestCase {
    private func env(collectAccessibility: Bool = true,
                     appVersion: String? = nil,
                     appBuild: String? = nil) -> [String: String] {
        EnvironmentCollector(sdkVersion: "9.9.9",
                             appVersion: appVersion,
                             appBuild: appBuild,
                             collectAccessibility: collectAccessibility).collect()
    }

    /// Mac Catalyst deliberately reports `ios`: it *is* an iOS target, and the
    /// Mac-ness surfaces in `run_context.target_environment` instead.
    func testPlatformMatchesTheHostPlatform() {
        #if os(macOS)
        XCTAssertEqual(env()["device.platform"], "macos")
        #elseif os(iOS)
        XCTAssertEqual(env()["device.platform"], "ios")
        #elseif os(tvOS)
        XCTAssertEqual(env()["device.platform"], "tvos")
        #elseif os(watchOS)
        XCTAssertEqual(env()["device.platform"], "watchos")
        #elseif os(visionOS)
        XCTAssertEqual(env()["device.platform"], "visionos")
        #else
        XCTFail("unhandled platform — add it here and to EnvironmentCollector.platform")
        #endif
    }

    func testSdkKeys() {
        XCTAssertEqual(env()["sdk.name"], "beaconstat-swift")
        XCTAssertEqual(env()["sdk.version"], "9.9.9")
    }

    func testOsKeysPresent() {
        let e = env()
        #if os(macOS)
        XCTAssertEqual(e["device.os_name"], "macOS")
        #elseif os(iOS)
        XCTAssertEqual(e["device.os_name"], "iOS")
        #elseif os(tvOS)
        XCTAssertEqual(e["device.os_name"], "tvOS")
        #elseif os(watchOS)
        XCTAssertEqual(e["device.os_name"], "watchOS")
        #elseif os(visionOS)
        XCTAssertEqual(e["device.os_name"], "visionOS")
        #endif
        XCTAssertNotNil(e["device.os_version"])
        XCTAssertNotNil(e["device.system_major_version"])
    }

    func testArchitectureIsKnown() {
        XCTAssertTrue(["arm64", "x86_64"].contains(env()["device.architecture"] ?? ""))
    }

    /// `device.orientation` is reported only where there is a single screen
    /// with an orientation to report. macOS has windows, visionOS has volumes
    /// in space, and watchOS has no `UIScreen` — all three omit it, and the
    /// wire format treats it as optional.
    func testOrientationIsReportedOnlyWhereThereIsOneToReport() {
        let orientation = env()["device.orientation"]
        #if os(iOS) || os(tvOS)
        XCTAssertTrue(["portrait", "landscape"].contains(orientation ?? ""), "\(orientation ?? "nil")")
        #else
        XCTAssertNil(orientation)
        #endif
    }

    func testExactlyOneRunContextFlagIsTrue() {
        let e = env()
        let flags = ["run_context.is_debug", "run_context.is_simulator",
                     "run_context.is_testflight", "run_context.is_app_store"]
        XCTAssertEqual(flags.filter { e[$0] == "true" }.count, 1)
        // All four keys must be present and boolean-valued.
        for f in flags { XCTAssertTrue(e[f] == "true" || e[f] == "false") }
    }

    /// `run_context.is_debug` reports the build configuration of the *SDK*, and
    /// it is what `.automatic` test-mode routing keys off. Asserting the Debug
    /// value only was safe while `swift test -c release` didn't compile; now that
    /// it does, this has to track the configuration or it fails there (test gap 6).
    func testDebugFlagTracksTheBuildConfiguration() {
        #if DEBUG
        XCTAssertEqual(env()["run_context.is_debug"], "true")
        #else
        XCTAssertEqual(env()["run_context.is_debug"], "false")
        #endif
    }

    /// Mirrors `EnvironmentCollector.targetEnvironment()`'s precedence:
    /// Catalyst beats simulator beats iOS-on-Mac beats native. The simulator
    /// branch is the one the old assertion could not see — it ran only on the
    /// host, where the answer is always `native`.
    func testTargetEnvironmentReflectsTheBuildContext() {
        let value = env()["run_context.target_environment"]
        #if targetEnvironment(macCatalyst)
        XCTAssertEqual(value, "mac_catalyst")
        #elseif targetEnvironment(simulator)
        XCTAssertEqual(value, "simulator")
        #elseif os(iOS)
        XCTAssertTrue(["ios_on_mac", "native"].contains(value ?? ""), "\(value ?? "nil")")
        #else
        XCTAssertEqual(value, "native")
        #endif
    }

    func testAppKeysOmittedWhenNil() {
        let e = env(appVersion: nil, appBuild: nil)
        XCTAssertNil(e["app.version"])
        XCTAssertNil(e["app.build"])
    }

    func testAppKeysIncludedWhenProvided() {
        let e = env(appVersion: "1.5.0", appBuild: "500")
        XCTAssertEqual(e["app.version"], "1.5.0")
        XCTAssertEqual(e["app.build"], "500")
    }

    func testLocaleAndTimezonePresent() {
        let e = env()
        XCTAssertNotNil(e["locale"])
        XCTAssertNotNil(e["timezone"])
    }

    func testColorSchemeIsLightOrDark() {
        XCTAssertTrue(["light", "dark"].contains(env()["user_preference.color_scheme"] ?? ""))
    }

    func testLayoutDirectionIsLtrOrRtl() {
        XCTAssertTrue(["ltr", "rtl"].contains(env()["user_preference.layout_direction"] ?? ""))
    }

    /// The five settings both `UIAccessibility` and `NSWorkspace` expose.
    /// watchOS has neither, so it reports none of them at all.
    func testTheSharedAccessibilityKeysArePresentWhereverThereIsAnAPI() throws {
        #if os(watchOS)
        throw XCTSkip("watchOS exposes no accessibility-settings API; the keys are omitted entirely")
        #else
        let e = env(collectAccessibility: true)
        XCTAssertNotNil(e["accessibility.reduce_motion"])
        XCTAssertNotNil(e["accessibility.reduce_transparency"])
        XCTAssertNotNil(e["accessibility.invert_colors"])
        XCTAssertNotNil(e["accessibility.darker_system_colors"])
        XCTAssertNotNil(e["accessibility.differentiate_without_color"])
        #endif
    }

    /// `bold_text` and `preferred_content_size` exist only on `UIAccessibility`
    /// / `UITraitCollection`. macOS has no equivalent and omits them; watchOS
    /// collects nothing at all.
    func testBoldTextAndContentSizeAreReportedOnlyWhereUIKitProvidesThem() {
        let e = env(collectAccessibility: true)
        #if canImport(UIKit) && !os(watchOS)
        XCTAssertEqual(e["accessibility.bold_text"].map { $0 == "true" || $0 == "false" }, true)
        XCTAssertNotNil(e["accessibility.preferred_content_size"])
        #else
        XCTAssertNil(e["accessibility.bold_text"])
        XCTAssertNil(e["accessibility.preferred_content_size"])
        #endif
    }

    func testAccessibilityDisabledOmitsAllAccessibilityKeys() {
        let e = env(collectAccessibility: false)
        XCTAssertTrue(e.keys.filter { $0.hasPrefix("accessibility.") }.isEmpty)
    }

    func testEveryEnvKeyIsContractValid() {
        // Contract guard: env keys match the key regex and never start with `_bcs.`.
        let e = env(collectAccessibility: true)
        let pattern = "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)*$"
        let regex = try! NSRegularExpression(pattern: pattern)
        for key in e.keys {
            XCTAssertFalse(key.hasPrefix("_bcs."), "env key must not start with _bcs.: \(key)")
            let range = NSRange(key.startIndex..., in: key)
            XCTAssertNotNil(regex.firstMatch(in: key, range: range), "invalid env key: \(key)")
            XCTAssertLessThanOrEqual(key.count, 100)
        }
        // All values are non-empty strings ≤ 1024 chars.
        for (key, value) in e {
            XCTAssertFalse(value.isEmpty, "empty value for \(key)")
            XCTAssertLessThanOrEqual(value.count, 1024)
        }
    }
}
