import Foundation

/// Controls how test events are routed (spec §4.6).
public enum TestMode: Equatable, Sendable {
    case automatic       // route to /v1/debug/events under DEBUG or simulator
    case forceProduction // always /v1/events
    case forceTest       // always /v1/debug/events
}

/// Tunable SDK behavior. Defaults are tuned for first-party dogfooding.
///
/// Every numeric field is **clamped** into the range documented on
/// `BeaconstatOptions.Limits` when the SDK is configured, and each clamp is
/// logged. Out-of-range values degrade the SDK's tuning rather than disabling
/// analytics, so a bad number never silently costs you data.
public struct BeaconstatOptions: Sendable {
    /// Accepted ranges for the numeric options.
    ///
    /// Values outside these bounds are clamped at `configure()` (and logged);
    /// non-finite `TimeInterval`s (`nan`, `±infinity`) fall back to the range
    /// floor. These bounds exist because the unclamped values are not merely
    /// odd — several of them break the SDK outright.
    public enum Limits {
        /// `5 s … 24 h`. The floor is load-bearing: `flushInterval: 0` schedules
        /// a `DispatchSourceTimer` with `repeating: 0`, which fires roughly
        /// 345,000 times per second, each fire pinning a core and issuing a
        /// synchronous Keychain read. `0` is the natural guess for
        /// "flush immediately" — use `flush()` for that instead.
        public static let flushInterval: ClosedRange<TimeInterval> = 5...86_400
        /// `1 s … 24 h`. At or below zero, every single event exceeds the
        /// inactivity window and starts a brand-new session (two Keychain
        /// writes and a `_bcs.session_started` event apiece).
        public static let sessionTimeout: ClosedRange<TimeInterval> = 1...86_400
        /// `1 … 10,000` events retained on disk. The queue is held in memory and
        /// rewritten in full on every enqueue, so the ceiling bounds both the
        /// resident size and the per-event write cost.
        public static let maxQueuedEvents: ClosedRange<Int> = 1...10_000
        /// `0 … 10` backoff retries per round. `0` disables the retry timer;
        /// the periodic flush, the next event, and reconnect still retry.
        public static let maxRetries: ClosedRange<Int> = 0...10
        /// `1 … 10,000` events, and additionally never above the effective
        /// `maxQueuedEvents`: past that the size trigger could never fire,
        /// because overflow eviction caps the queue below the threshold.
        /// `0` would make `count >= batchSize` always true — a flush per event.
        public static let batchSize: ClosedRange<Int> = 1...10_000
    }

    public var testMode: TestMode
    /// Flush when this many events are queued. Clamped to
    /// `Limits.batchSize` ∩ `1...maxQueuedEvents`.
    public var batchSize: Int
    /// Seconds between periodic flushes. Clamped to `Limits.flushInterval`.
    public var flushInterval: TimeInterval
    public var flushOnBackground: Bool
    /// Inactivity window before a new session starts. Clamped to
    /// `Limits.sessionTimeout`.
    public var sessionTimeout: TimeInterval
    /// Maximum events retained on disk. Clamped to `Limits.maxQueuedEvents`.
    public var maxQueuedEvents: Int
    /// Backoff retries per failed round. Clamped to `Limits.maxRetries`.
    public var maxRetries: Int
    public var debugLogging: Bool
    public var collectAccessibility: Bool
    /// Override the ingest base URL (dev / self-host). Defaults to production.
    public var endpoint: URL?
    /// The host app's version, sent on the wire as `productVersion`. The
    /// facade fills this from `CFBundleShortVersionString` when left `nil`.
    public var productVersion: String?
    /// Under `.automatic` test mode, also route TestFlight builds to the test
    /// endpoint. Defaults to `false` — TestFlight is a pre-release channel
    /// closer to production; opt in if you want beta data segregated.
    public var routeTestFlightToTest: Bool

    public init(
        testMode: TestMode = .automatic,
        batchSize: Int = 50,
        flushInterval: TimeInterval = BeaconstatOptions.defaultFlushInterval,
        flushOnBackground: Bool = true,
        sessionTimeout: TimeInterval = 300,
        maxQueuedEvents: Int = 500,
        maxRetries: Int = 3,
        debugLogging: Bool = false,
        collectAccessibility: Bool = true,
        endpoint: URL? = nil,
        productVersion: String? = nil,
        routeTestFlightToTest: Bool = false
    ) {
        self.testMode = testMode
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.flushOnBackground = flushOnBackground
        self.sessionTimeout = sessionTimeout
        self.maxQueuedEvents = maxQueuedEvents
        self.maxRetries = maxRetries
        self.debugLogging = debugLogging
        self.collectAccessibility = collectAccessibility
        self.endpoint = endpoint
        self.productVersion = productVersion
        self.routeTestFlightToTest = routeTestFlightToTest
    }

    /// `productVersion` on the wire, defaulted when the host didn't set one
    /// (and the facade couldn't find `CFBundleShortVersionString`).
    var productVersionOrDefault: String { productVersion ?? "0.0.0" }

    /// Build-config-aware flush cadence: fast in development, battery/data
    /// friendly in release. Overridable via `flushInterval`.
    public static var defaultFlushInterval: TimeInterval {
        #if DEBUG
        return 30       // seconds — fast local feedback
        #else
        return 14_400   // seconds (4h) — timely release sends come from flushOnBackground
        #endif
    }
}
