import Foundation

/// Public entry point for the BeaconStat Swift SDK.
///
/// Forwards to `BeaconstatCore`, a thread-safe orchestrator on a serial queue.
/// The public surface here is frozen.
public enum Beaconstat {
    /// Configure the SDK. `hmacSecret` is the 64-char hex signing secret
    /// (NOT the `bcs_sec_…` key). Never throws into the host.
    public static func configure(publicKey: String, hmacSecret: String) {
        configure(publicKey: publicKey, hmacSecret: hmacSecret, options: BeaconstatOptions())
    }

    public static func configure(publicKey: String, hmacSecret: String, options: BeaconstatOptions) {
        // Snapshot environment + app version on the CALLER's thread (App init = main),
        // so UIKit state is never read from the core's serial background queue.
        var opts = options
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let appBuild = bundle.infoDictionary?["CFBundleVersion"] as? String
        if opts.productVersion == nil { opts.productVersion = appVersion }
        let environment = EnvironmentCollector(sdkVersion: BeaconstatVersion.current,
                                               appVersion: appVersion, appBuild: appBuild,
                                               collectAccessibility: opts.collectAccessibility).collect()
        BeaconstatCore.shared.configure(publicKey: publicKey, hmacSecret: hmacSecret,
                                        options: opts, environment: environment)
    }

    /// Track a custom event. Property values are strings.
    public static func track(_ name: String, properties: [String: String] = [:]) {
        BeaconstatCore.shared.track(name, properties: properties)
    }

    /// Force-send queued events (best-effort, async).
    public static func flush() { BeaconstatCore.shared.flush() }

    /// Host-controlled kill switch. When opted out, the SDK collects/sends nothing.
    public static func optOut() { BeaconstatCore.shared.optOut() }

    public static func optIn() { BeaconstatCore.shared.optIn() }

    public static var isOptedOut: Bool { BeaconstatCore.shared.isOptedOut }

    /// Report a URL entry point (custom scheme or universal link). Only the
    /// scheme + host are recorded — never the path, query, or fragment.
    public static func opened(from url: URL) { BeaconstatCore.shared.trackOpenURL(url) }

    /// Report an `NSUserActivity` continuation (Handoff / universal link activity).
    public static func openedFromActivity(webpageURL: URL?) {
        BeaconstatCore.shared.trackOpenActivity(webpageURL)
    }
}
