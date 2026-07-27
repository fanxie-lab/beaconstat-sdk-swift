import Foundation
import os

/// Diagnostic channel, off unless the host asks for it (or the SDK itself is a
/// Debug build).
///
/// ## Why `os.Logger` and not `print` (L6)
///
/// The default sink used to be `print("[Beaconstat] …")`. Three problems, in
/// increasing order of seriousness:
///
/// - **Unfilterable.** A library writing to stdout cannot be turned off, routed,
///   or searched by an adopter. `os.Logger` carries a subsystem and category, so
///   `log stream --predicate 'subsystem == "com.beaconstat.sdk"'` isolates the
///   SDK's output from the host app's, and Console can filter on it.
/// - **Unstructured and unarchived.** `print` output does not appear in a
///   sysdiagnose, so a field report of "the SDK stopped sending" arrives with no
///   evidence. Unified-logging records do.
/// - **Expensive in the wrong place.** `print` formats and writes eagerly on the
///   calling thread — here, the core's serial queue, i.e. in front of every
///   event. `os_log` hands a pre-formatted record to the logging daemon.
///
/// Level is `.debug` deliberately: these are opt-in diagnostics, so even a host
/// that ships with `debugLogging = true` cannot fill a production log archive.
/// Read them with:
///
/// ```
/// log stream --predicate 'subsystem == "com.beaconstat.sdk"' --level debug
/// ```
///
/// ## Privacy
///
/// Messages are interpolated `.public`, because `os_log` otherwise redacts every
/// dynamic string to `<private>` and the channel becomes useless. That is only
/// sound because of an invariant the SDK holds deliberately and
/// `LoggerPrivacyTests` enforces: **no property value, no environment value, no
/// credential and no site token is ever passed to the logger.** Call sites log
/// event names, property *keys*, error cases, byte counts and clamp notices —
/// developer-authored identifiers and SDK-controlled text, all of which already
/// travel on the wire. Anything user-supplied stays out.
///
/// `Sendable` for real, not `@unchecked`: both stored properties are immutable
/// and of `Sendable` type. That matters — the logger is captured by `Transport`'s
/// completion handlers and by `EventQueue`, so a non-`Sendable` logger produced
/// concurrency warnings at a dozen unrelated sites (M13).
final class Logger: Sendable {
    /// Reverse-DNS, matching the Keychain service, so an adopter has one string
    /// to filter on across logs and Keychain items.
    static let subsystem = "com.beaconstat.sdk"
    static let category = "Beaconstat"

    private static let osLog = os.Logger(subsystem: Logger.subsystem, category: Logger.category)

    private let enabled: Bool
    private let sink: @Sendable (String) -> Void

    /// - Parameter sink: where messages go. Defaults to unified logging;
    ///   injected by tests, which need to read what was written.
    init(enabled: Bool, sink: @escaping @Sendable (String) -> Void = { message in
        Logger.osLog.debug("\(message, privacy: .public)")
    }) {
        self.enabled = enabled
        self.sink = sink
    }

    /// `@autoclosure` so a disabled logger costs nothing but a branch — the
    /// interpolation never runs.
    func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        sink(message())
    }
}
