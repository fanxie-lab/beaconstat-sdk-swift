import Foundation

/// Public entry point for the BeaconStat Swift SDK.
///
/// Phase 1: all methods are no-ops that compile. Phase 2 forwards these to a
/// thread-safe core on a serial queue. The public surface here is frozen.
public enum Beaconstat {
    /// Configure the SDK. `hmacSecret` is the 64-char hex signing secret
    /// (NOT the `bcs_sec_…` key). Never throws into the host.
    public static func configure(publicKey: String, hmacSecret: String) {
        configure(publicKey: publicKey, hmacSecret: hmacSecret, options: BeaconstatOptions())
    }

    public static func configure(publicKey: String, hmacSecret: String, options: BeaconstatOptions) {
        // No-op in Phase 1.
    }

    /// Track a custom event. Property values are strings.
    public static func track(_ name: String, properties: [String: String] = [:]) {
        // No-op in Phase 1.
    }

    /// Force-send queued events (best-effort, async).
    public static func flush() {
        // No-op in Phase 1.
    }

    /// Host-controlled kill switch. When opted out, the SDK collects/sends nothing.
    public static func optOut() {
        // No-op in Phase 1.
    }

    public static func optIn() {
        // No-op in Phase 1.
    }

    public static var isOptedOut: Bool { false }
}
