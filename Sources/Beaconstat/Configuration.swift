import Foundation

/// Validated SDK configuration. `init` throws on bad credentials; the public
/// facade catches and disables the SDK rather than surfacing the error.
///
/// Numeric options are *clamped*, not rejected (H4): a nonsensical
/// `flushInterval` should cost you flush cadence, not all of your analytics.
/// Every clamp is recorded in `clampNotices` for the core to log.
struct Configuration {
    let publicKey: String
    let hmacSecret: String
    let baseURL: URL
    /// The host's options with every numeric field clamped into
    /// `BeaconstatOptions.Limits`. Always use this, never the raw options.
    let options: BeaconstatOptions
    /// One note per clamped field, for the core to log at `configure()`.
    /// Empty when the host's options were already in range.
    let clampNotices: [String]

    enum ValidationError: Error, Equatable {
        case invalidPublicKey
        case invalidHmacSecret
        /// The endpoint is not `https://` and `allowInsecureEndpoint` was not
        /// set — or its scheme isn't HTTP at all (M11).
        case insecureEndpoint
    }

    static let defaultBaseURL = URL(string: "https://ingest.beaconstat.com")!

    init(publicKey: String, hmacSecret: String, options: BeaconstatOptions) throws {
        // Public key: "bcs_pub_" prefix with a non-empty body.
        let prefix = "bcs_pub_"
        guard publicKey.hasPrefix(prefix), publicKey.count > prefix.count else {
            throw ValidationError.invalidPublicKey
        }
        // HMAC secret: exactly 64 hex characters.
        guard hmacSecret.count == 64, hmacSecret.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ValidationError.invalidHmacSecret
        }
        self.publicKey = publicKey
        self.hmacSecret = hmacSecret
        var (clampedOptions, notices) = Self.clamped(options)
        // Read from the clamped copy for consistency with everything else, even
        // though `endpoint` itself isn't a numeric that gets clamped.
        let endpoint = clampedOptions.endpoint ?? Configuration.defaultBaseURL
        if let notice = try Self.validateEndpoint(endpoint,
                                                 allowInsecure: clampedOptions.allowInsecureEndpoint) {
            notices.append(notice)
        }
        clampedOptions.endpoint = endpoint
        self.options = clampedOptions
        self.clampNotices = notices
        self.baseURL = endpoint
    }

    /// Rejects an endpoint that would put the site token and the HMAC signature
    /// on the wire in cleartext (M11).
    ///
    /// - Returns: a notice to log when cleartext was explicitly allowed.
    private static func validateEndpoint(_ url: URL, allowInsecure: Bool) throws -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw ValidationError.insecureEndpoint
        }
        if scheme == "https" { return nil }
        // The opt-in relaxes the check to `http`, not to `file`, `ftp` or
        // anything else that happens to parse as a URL.
        guard scheme == "http", allowInsecure else {
            throw ValidationError.insecureEndpoint
        }
        return "endpoint \(scheme)://\(host) sends the site token and the request signature "
            + "in cleartext — allowInsecureEndpoint is set, so this is intentional; never ship it"
    }

    /// Brings every numeric option inside `BeaconstatOptions.Limits`.
    static func clamped(_ options: BeaconstatOptions) -> (BeaconstatOptions, [String]) {
        typealias Limits = BeaconstatOptions.Limits
        var opts = options
        var notices: [String] = []

        func clamp<T: Comparable>(_ value: inout T, to range: ClosedRange<T>, _ name: String) {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            guard clamped != value else { return }
            notices.append("\(name) \(value) is outside \(range.lowerBound)…\(range.upperBound) — clamped to \(clamped)")
            value = clamped
        }

        /// `Swift.min`/`max` propagate NaN (every NaN comparison is false), so a
        /// non-finite interval would survive an ordinary clamp untouched.
        func clampInterval(_ value: inout TimeInterval, to range: ClosedRange<TimeInterval>, _ name: String) {
            guard value.isFinite else {
                notices.append("\(name) \(value) is not a finite number — using \(range.lowerBound)")
                value = range.lowerBound
                return
            }
            clamp(&value, to: range, name)
        }

        clampInterval(&opts.flushInterval, to: Limits.flushInterval, "flushInterval")
        clampInterval(&opts.sessionTimeout, to: Limits.sessionTimeout, "sessionTimeout")
        clamp(&opts.maxQueuedEvents, to: Limits.maxQueuedEvents, "maxQueuedEvents")
        clamp(&opts.maxRetries, to: Limits.maxRetries, "maxRetries")
        // batchSize last: its ceiling is the *clamped* maxQueuedEvents, because
        // above that the size trigger can never fire (overflow eviction caps the
        // queue before `count >= batchSize` is ever true).
        clamp(&opts.batchSize,
              to: Limits.batchSize.lowerBound...min(Limits.batchSize.upperBound, opts.maxQueuedEvents),
              "batchSize")

        return (opts, notices)
    }
}
