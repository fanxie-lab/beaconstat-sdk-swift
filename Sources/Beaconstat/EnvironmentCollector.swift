import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Builds the wire `environment` dictionary. All values are strings; absent
/// keys are omitted (never `""`). Key names are frozen (spec §4.9).
struct EnvironmentCollector {
    let sdkVersion: String
    let appVersion: String?
    let appBuild: String?
    let collectAccessibility: Bool

    init(sdkVersion: String, appVersion: String?, appBuild: String?, collectAccessibility: Bool) {
        self.sdkVersion = sdkVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.collectAccessibility = collectAccessibility
    }

    func collect() -> [String: String] {
        var env: [String: String] = [:]
        env.merge(deviceKeys()) { _, new in new }
        env.merge(sdkKeys()) { _, new in new }
        env.merge(runContextKeys()) { _, new in new }
        return env
    }

    // MARK: - device.*

    private func deviceKeys() -> [String: String] {
        var d: [String: String] = [:]
        d["device.platform"] = Self.platform
        if let model = Self.hardwareModel() { d["device.model"] = model }
        d["device.os_name"] = Self.osName
        let version = ProcessInfo.processInfo.operatingSystemVersion
        d["device.os_version"] = Self.osVersionString(version)
        d["device.system_major_version"] = String(version.majorVersion)
        d["device.architecture"] = Self.architecture
        if let screen = Self.screenMetrics() {
            d["device.screen_width"] = String(screen.width)
            d["device.screen_height"] = String(screen.height)
            d["device.screen_scale"] = String(screen.scale)
            if let orientation = screen.orientation { d["device.orientation"] = orientation }
        }
        return d
    }

    // MARK: - sdk.*

    private func sdkKeys() -> [String: String] {
        ["sdk.name": "beaconstat-swift", "sdk.version": sdkVersion]
    }

    // MARK: - run_context.*

    private func runContextKeys() -> [String: String] {
        let flags = Self.runContextFlags()
        return [
            "run_context.is_debug": flags.debug ? "true" : "false",
            "run_context.is_simulator": flags.simulator ? "true" : "false",
            "run_context.is_testflight": flags.testflight ? "true" : "false",
            "run_context.is_app_store": flags.appStore ? "true" : "false",
            "run_context.target_environment": Self.targetEnvironment(),
        ]
    }

    /// Exactly one flag is true, with precedence debug > simulator > testflight > app_store.
    static func runContextFlags() -> (debug: Bool, simulator: Bool, testflight: Bool, appStore: Bool) {
        var debug = false
        #if DEBUG
        debug = true
        #endif
        var simulatorBuild = false
        #if targetEnvironment(simulator)
        simulatorBuild = true
        #endif
        let simulator = simulatorBuild && !debug
        let testflight = !debug && !simulator && isSandboxReceipt()
        let appStore = !debug && !simulator && !testflight
        return (debug, simulator, testflight, appStore)
    }

    static func targetEnvironment() -> String {
        #if targetEnvironment(macCatalyst)
        return "mac_catalyst"
        #elseif targetEnvironment(simulator)
        return "simulator"
        #elseif os(iOS)
        return ProcessInfo.processInfo.isiOSAppOnMac ? "ios_on_mac" : "native"
        #else
        return "native"
        #endif
    }

    static func isSandboxReceipt() -> Bool {
        #if os(iOS) || os(macOS)
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.lastPathComponent == "sandboxReceipt"
        #else
        return false
        #endif
    }

    // MARK: - Static platform helpers

    static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #else
        return "unknown"
        #endif
    }

    static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "unknown"
        #endif
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(arm)
        return "arm"
        #elseif arch(i386)
        return "i386"
        #else
        return "unknown"
        #endif
    }

    static func osVersionString(_ v: OperatingSystemVersion) -> String {
        v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
    }

    static func hardwareModel() -> String? {
        #if targetEnvironment(simulator)
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        #endif
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    struct ScreenMetrics { let width: Int; let height: Int; let scale: Int; let orientation: String? }

    static func screenMetrics() -> ScreenMetrics? {
        #if canImport(UIKit) && !os(watchOS)
        let screen = UIScreen.main
        let bounds = screen.bounds
        let width = Int(bounds.width.rounded())
        let height = Int(bounds.height.rounded())
        let orientation = height >= width ? "portrait" : "landscape"
        return ScreenMetrics(width: width, height: height,
                             scale: Int(screen.scale.rounded()), orientation: orientation)
        #elseif os(macOS)
        guard let screen = NSScreen.main else { return nil }
        let frame = screen.frame
        return ScreenMetrics(width: Int(frame.width.rounded()),
                             height: Int(frame.height.rounded()),
                             scale: Int(screen.backingScaleFactor.rounded()),
                             orientation: nil)
        #else
        return nil
        #endif
    }
}
