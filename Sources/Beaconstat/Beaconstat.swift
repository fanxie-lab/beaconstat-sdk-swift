import Foundation

/// Public entry point for the BeaconStat Swift SDK.
///
/// Forwards to `BeaconstatCore`, a thread-safe orchestrator on a serial queue.
/// The public surface here is frozen.
public enum Beaconstat {
    /// Configure the SDK. `hmacSecret` is the 64-char hex signing secret
    /// (NOT the `bcs_sec_…` key). Never throws into the host.
    ///
    /// Must be called on the main thread — hence `@MainActor`. It snapshots
    /// main-thread-only UI state (`UIScreen.main`, `UITraitCollection.current`,
    /// `UIAccessibility`), which off main yields defaults for `device.screen_*`,
    /// `device.orientation`, `user_preference.color_scheme` and every
    /// `accessibility.*` key. Call it from `App.init`, `didFinishLaunching`, or
    /// any other main-actor context.
    @MainActor
    public static func configure(publicKey: String, hmacSecret: String) {
        configure(publicKey: publicKey, hmacSecret: hmacSecret, options: BeaconstatOptions())
    }

    /// Configure the SDK with explicit options. Main-thread-only — see
    /// `configure(publicKey:hmacSecret:)`.
    @MainActor
    public static func configure(publicKey: String, hmacSecret: String, options: BeaconstatOptions) {
        var opts = options
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let appBuild = bundle.infoDictionary?["CFBundleVersion"] as? String
        if opts.productVersion == nil { opts.productVersion = appVersion }
        let collector = EnvironmentCollector(sdkVersion: BeaconstatVersion.current,
                                             appVersion: appVersion, appBuild: appBuild,
                                             collectAccessibility: opts.collectAccessibility)
        // Only the genuinely main-bound reads happen here. Everything else —
        // `sysctlbyname`, the App Store receipt URL, `Locale`, `TimeZone` — is
        // handed to the core as a closure and collected on its serial queue,
        // strictly before routing and the handshake read it, so it leaves the
        // launch critical path without racing anything (M6).
        let mainThreadEnvironment = EnvironmentCollector
            .collectMainThreadOnly(collectAccessibility: opts.collectAccessibility)
        BeaconstatCore.shared.configure(publicKey: publicKey, hmacSecret: hmacSecret,
                                        options: opts, environment: mainThreadEnvironment,
                                        deferredEnvironment: { collector.collectDeferrable() })
    }

    /// Track a custom event. Property values are strings.
    public static func track(_ name: String, properties: [String: String] = [:]) {
        BeaconstatCore.shared.track(name, properties: properties)
    }

    /// Force-send queued events (best-effort, async).
    public static func flush() { BeaconstatCore.shared.flush() }

    /// Stop all SDK activity and release the OS resources it holds: the periodic
    /// flush and retry timers, the network-path monitor, the app lifecycle
    /// observers, and the `URLSession` (which retains itself until invalidated).
    ///
    /// Queued events stay on disk; call `flush()` first if you want a final send
    /// attempt. Optional — configure once at launch and you never need this. It
    /// exists so a host *can* release everything, and so tests can tear the SDK
    /// down deterministically. Safe to call repeatedly, and `configure()`
    /// afterwards brings the SDK back.
    public static func shutdown() { BeaconstatCore.shared.shutdown() }

    /// Host-controlled kill switch. While opted out the SDK collects and sends
    /// nothing, and it also stops doing *work*: timers, the network-path monitor
    /// and the lifecycle observers are torn down.
    ///
    /// This also purges local identity — `install_id`, the site token and
    /// session history — so it doubles as the device half of a "delete my data"
    /// request. A later `optIn()` therefore starts a fresh anonymous install.
    /// The opt-out flag itself persists across launches.
    public static func optOut() { BeaconstatCore.shared.optOut() }

    /// Resume collection after `optOut()`.
    ///
    /// Works in the documented consent order — `optOut()` → `configure()` →
    /// `optIn()` — because `configure()` completes setup even while opted out
    /// and only collection is gated. If `configure()` hasn't run yet, collection
    /// starts when it does.
    public static func optIn() { BeaconstatCore.shared.optIn() }

    public static var isOptedOut: Bool { BeaconstatCore.shared.isOptedOut }

    /// Report a URL entry point (custom scheme or universal link). Only the
    /// scheme + host are recorded — never the path, query, or fragment.
    public static func opened(from url: URL) { BeaconstatCore.shared.trackOpenURL(url) }

    /// Report an `NSUserActivity` continuation (Handoff / universal link activity).
    public static func openedFromActivity(webpageURL: URL?) {
        BeaconstatCore.shared.trackOpenActivity(webpageURL)
    }

    /// Report an iOS home-screen quick-action launch.
    public static func openedFromShortcut(type: String) { BeaconstatCore.shared.trackShortcut(type) }

    /// Report a launch from a WidgetKit widget / complication / Live Activity deep link.
    public static func openedFromWidget(kind: String?, family: String?) {
        BeaconstatCore.shared.trackWidget(kind: kind, family: family)
    }

    /// Report a delivered notification (opt-in). Only `category` + `wasSilent`
    /// are recorded — never the notification body, title, or userInfo.
    public static func pushReceived(category: String?, wasSilent: Bool) {
        BeaconstatCore.shared.trackPushReceived(category: category, wasSilent: wasSilent)
    }

    /// Report the user opening/acting on a notification (opt-in). Only
    /// `category` + `actionId` are recorded.
    public static func pushOpened(category: String?, actionId: String?) {
        BeaconstatCore.shared.trackPushOpened(category: category, actionId: actionId)
    }
}
