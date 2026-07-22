import XCTest
@testable import Beaconstat

final class EnvironmentCollectorTests: XCTestCase {
    private func env(collectAccessibility: Bool = true,
                     appVersion: String? = nil,
                     appBuild: String? = nil) -> [String: String] {
        EnvironmentCollector(sdkVersion: "9.9.9",
                             appVersion: appVersion,
                             appBuild: appBuild,
                             collectAccessibility: collectAccessibility).collect()
    }

    func testPlatformIsMacOSOnHost() {
        XCTAssertEqual(env()["device.platform"], "macos")
    }

    func testSdkKeys() {
        XCTAssertEqual(env()["sdk.name"], "beaconstat-swift")
        XCTAssertEqual(env()["sdk.version"], "9.9.9")
    }

    func testOsKeysPresent() {
        let e = env()
        XCTAssertEqual(e["device.os_name"], "macOS")
        XCTAssertNotNil(e["device.os_version"])
        XCTAssertNotNil(e["device.system_major_version"])
    }

    func testArchitectureIsKnown() {
        XCTAssertTrue(["arm64", "x86_64"].contains(env()["device.architecture"] ?? ""))
    }

    func testNoOrientationOnMac() {
        XCTAssertNil(env()["device.orientation"])
    }

    func testExactlyOneRunContextFlagIsTrue() {
        let e = env()
        let flags = ["run_context.is_debug", "run_context.is_simulator",
                     "run_context.is_testflight", "run_context.is_app_store"]
        XCTAssertEqual(flags.filter { e[$0] == "true" }.count, 1)
        // All four keys must be present and boolean-valued.
        for f in flags { XCTAssertTrue(e[f] == "true" || e[f] == "false") }
    }

    func testDebugIsTrueUnderSwiftTest() {
        XCTAssertEqual(env()["run_context.is_debug"], "true")
    }

    func testTargetEnvironmentIsNativeOnMac() {
        XCTAssertEqual(env()["run_context.target_environment"], "native")
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
}
