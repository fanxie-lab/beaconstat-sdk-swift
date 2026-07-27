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
        (self.options, self.clampNotices) = Self.clamped(options)
        self.baseURL = options.endpoint ?? Configuration.defaultBaseURL
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
