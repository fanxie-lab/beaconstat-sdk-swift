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

    /// The complete snapshot.
    ///
    /// `@MainActor` because part of it is main-thread-only UI state (M1). Prefer
    /// `collectMainThreadOnly()` + `collectDeferrable()` on the launch path, so
    /// only the UI reads pay for being on main (M6).
    @MainActor
    func collect() -> [String: String] {
        var env = collectDeferrable()
        env.merge(Self.collectMainThreadOnly(collectAccessibility: collectAccessibility)) { _, new in new }
        return env
    }

    /// The half that MUST be read on the main thread: `UIScreen.main`,
    /// `UITraitCollection.current`, and the `UIAccessibility` /
    /// `NSWorkspace` accessibility flags.
    ///
    /// Reading these off main trips the Main Thread Checker and yields defaults,
    /// so `device.screen_*`, `device.orientation`,
    /// `user_preference.color_scheme` and every `accessibility.*` key silently
    /// go wrong (M1). Cheap — these are property reads, not syscalls — so it
    /// stays synchronous on the launch path.
    ///
    /// This is also the **volatile** half: every value here can change while the
    /// app runs (rotation, iPad multitasking resize, Dark Mode, an accessibility
    /// setting toggled in Settings), which is why the core re-reads it on every
    /// foreground transition (L1).
    @MainActor
    static func collectMainThreadOnly(collectAccessibility: Bool) -> [String: String] {
        collectMainThreadOnlyAssumingMainThread(collectAccessibility: collectAccessibility)
    }

    /// The same snapshot, without the `@MainActor` the compiler can check.
    ///
    /// **The caller guarantees it is already on the main thread.** This exists
    /// for exactly one call site: the core's foreground refresh, which runs
    /// inside `DispatchQueue.main.async` (L1). That *is* the main thread, but
    /// the only way to tell the compiler so is `MainActor.assumeIsolated`, which
    /// needs iOS 17 / macOS 14 while this package deploys to iOS 15 / macOS 12.
    ///
    /// Prefer `collectMainThreadOnly` everywhere the annotation can be honoured.
    static func collectMainThreadOnlyAssumingMainThread(collectAccessibility: Bool) -> [String: String] {
        var d: [String: String] = [:]
        if let screen = screenMetrics() {
            d["device.screen_width"] = String(screen.width)
            d["device.screen_height"] = String(screen.height)
            d["device.screen_scale"] = String(screen.scale)
            if let orientation = screen.orientation { d["device.orientation"] = orientation }
        }
        d["user_preference.color_scheme"] = colorScheme()
        if collectAccessibility {
            d.merge(accessibilityKeys()) { _, new in new }
        }
        return d
    }

    /// The half that is safe — and at launch much better — off the main thread:
    /// `sysctlbyname`, the App Store receipt URL, `Locale`, `TimeZone`,
    /// `ProcessInfo`, and the compile-time keys (M6).
    func collectDeferrable() -> [String: String] {
        var env: [String: String] = [:]
        env.merge(deviceKeys()) { _, new in new }
        env.merge(sdkKeys()) { _, new in new }
        env.merge(runContextKeys()) { _, new in new }
        env.merge(appAndLocaleKeys()) { _, new in new }
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

    // MARK: - app.* / locale / timezone / user_preference.*

    private func appAndLocaleKeys() -> [String: String] {
        var d: [String: String] = [:]
        if let appVersion { d["app.version"] = appVersion }
        if let appBuild { d["app.build"] = appBuild }
        d["locale"] = Locale.current.identifier
        d["timezone"] = TimeZone.current.identifier
        let (language, region) = Self.languageAndRegion()
        if let language { d["user_preference.language"] = language }
        if let region { d["user_preference.region"] = region }
        // `user_preference.color_scheme` lives in the main-thread half —
        // `UITraitCollection.current` is main-only.
        d["user_preference.layout_direction"] = Self.layoutDirection(language: language)
        return d
    }

    static func languageAndRegion() -> (String?, String?) {
        if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
            return (Locale.current.language.languageCode?.identifier,
                    Locale.current.region?.identifier)
        } else {
            return (Locale.current.languageCode, Locale.current.regionCode)
        }
    }

    /// Main-thread-only (`UITraitCollection.current`). The `@MainActor`
    /// annotation lives on `collectMainThreadOnly`, the entry point callers
    /// use; this stays unannotated so the nonisolated refresh path can reach it
    /// (see `collectMainThreadOnlyAssumingMainThread`).
    static func colorScheme() -> String {
        #if canImport(UIKit) && !os(watchOS)
        return UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
        #elseif os(macOS)
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
        return isDark ? "dark" : "light"
        #else
        return "light"
        #endif
    }

    /// `Locale.characterDirection(forLanguage:)` is deprecated in favour of
    /// `Locale.Language.characterDirection`, which needs iOS 16 / macOS 13 /
    /// tvOS 16 / watchOS 9 — above this package's floor, but *below* visionOS 1,
    /// so building for visionOS surfaced the deprecation as a warning while the
    /// other platforms stayed silent. Branch rather than suppress: adopters on
    /// iOS 15 keep working, and everyone else uses the supported API.
    static func layoutDirection(language: String?) -> String {
        let lang = language ?? Locale.current.identifier
        let direction: Locale.LanguageDirection
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            direction = Locale.Language(identifier: lang).characterDirection
        } else {
            direction = Locale.characterDirection(forLanguage: lang)
        }
        return direction == .rightToLeft ? "rtl" : "ltr"
    }

    // MARK: - accessibility.*

    /// Main-thread-only — see `colorScheme()` for why it isn't `@MainActor`.
    private static func accessibilityKeys() -> [String: String] {
        var d: [String: String] = [:]
        #if canImport(UIKit) && !os(watchOS)
        d["accessibility.bold_text"] = UIAccessibility.isBoldTextEnabled ? "true" : "false"
        d["accessibility.reduce_motion"] = UIAccessibility.isReduceMotionEnabled ? "true" : "false"
        d["accessibility.reduce_transparency"] = UIAccessibility.isReduceTransparencyEnabled ? "true" : "false"
        d["accessibility.invert_colors"] = UIAccessibility.isInvertColorsEnabled ? "true" : "false"
        d["accessibility.darker_system_colors"] = UIAccessibility.isDarkerSystemColorsEnabled ? "true" : "false"
        d["accessibility.differentiate_without_color"] = UIAccessibility.shouldDifferentiateWithoutColor ? "true" : "false"
        d["accessibility.preferred_content_size"] = Self.contentSizeToken(UITraitCollection.current.preferredContentSizeCategory)
        #elseif os(macOS)
        let workspace = NSWorkspace.shared
        d["accessibility.reduce_motion"] = workspace.accessibilityDisplayShouldReduceMotion ? "true" : "false"
        d["accessibility.reduce_transparency"] = workspace.accessibilityDisplayShouldReduceTransparency ? "true" : "false"
        d["accessibility.invert_colors"] = workspace.accessibilityDisplayShouldInvertColors ? "true" : "false"
        d["accessibility.darker_system_colors"] = workspace.accessibilityDisplayShouldIncreaseContrast ? "true" : "false"
        d["accessibility.differentiate_without_color"] = workspace.accessibilityDisplayShouldDifferentiateWithoutColor ? "true" : "false"
        // bold_text and preferred_content_size have no macOS API → omitted.
        #endif
        return d
    }

    #if canImport(UIKit) && !os(watchOS)
    static func contentSizeToken(_ category: UIContentSizeCategory) -> String {
        switch category {
        case .extraSmall: return "XS"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .extraLarge: return "XL"
        case .extraExtraLarge: return "XXL"
        case .extraExtraExtraLarge: return "XXXL"
        case .accessibilityMedium: return "AX1"
        case .accessibilityLarge: return "AX2"
        case .accessibilityExtraLarge: return "AX3"
        case .accessibilityExtraExtraLarge: return "AX4"
        case .accessibilityExtraExtraExtraLarge: return "AX5"
        default: return "L"
        }
    }
    #endif

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
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // `String(cString:)` on an array is deprecated (it was the last warning
        // in a Swift 6 build, M13). Truncating at the NUL ourselves is also
        // strictly safer: the deprecated initialiser reads to the first NUL and
        // trusts one to exist, whereas `sysctlbyname` reports the buffer length,
        // and a value that exactly filled it would have no terminator.
        let bytes = buffer.prefix { $0 != 0 }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    struct ScreenMetrics { let width: Int; let height: Int; let scale: Int; let orientation: String? }

    /// Main-thread-only (`UIScreen.main`) — see `colorScheme()` for why it
    /// isn't `@MainActor`.
    ///
    /// **visionOS reports nothing, deliberately.** `UIScreen` is
    /// `API_UNAVAILABLE(visionos)`, so this did not merely return a wrong value
    /// there — the SDK **did not compile for visionOS at all**, while the README
    /// and CHANGELOG advertised it and `Package.swift` didn't declare it, so
    /// nothing ever tried (L9). There is also no sensible value to report: a
    /// visionOS app has no screen, it has one or more volumes and windows the
    /// user resizes and moves in space, and `device.screen_*` would be a
    /// fabrication. Omitting the keys is the honest answer, and the wire format
    /// already treats them as optional.
    static func screenMetrics() -> ScreenMetrics? {
        #if os(visionOS)
        return nil
        #elseif canImport(UIKit) && !os(watchOS)
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
