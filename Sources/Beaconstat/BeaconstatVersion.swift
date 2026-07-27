/// SDK package version, sent on the wire as the `sdk.version` environment key.
///
/// This is the single source of truth. `BeaconstatCore` deliberately does *not*
/// hold a copy: it used to take an `sdkVersion` init parameter that was stored
/// and never read, so every core test passed `"9.9.9"` believing it reached the
/// wire (L5). The value comes from here, via `EnvironmentCollector`, in the
/// facade.
enum BeaconstatVersion {
    static let current = "1.1.0"
}
