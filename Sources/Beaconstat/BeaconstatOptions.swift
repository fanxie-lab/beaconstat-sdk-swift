import Foundation

/// Controls how test events are routed (spec §4.6).
public enum TestMode: Equatable, Sendable {
    case automatic       // route to /v1/debug/events under DEBUG or simulator
    case forceProduction // always /v1/events
    case forceTest       // always /v1/debug/events
}

/// Tunable SDK behavior. Defaults are tuned for first-party dogfooding.
public struct BeaconstatOptions: Sendable {
    public var testMode: TestMode
    public var batchSize: Int
    public var flushInterval: TimeInterval
    public var flushOnBackground: Bool
    public var sessionTimeout: TimeInterval
    public var maxQueuedEvents: Int
    public var maxRetries: Int
    public var debugLogging: Bool
    public var collectAccessibility: Bool
    /// Override the ingest base URL (dev / self-host). Defaults to production.
    public var endpoint: URL?

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
        endpoint: URL? = nil
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
    }

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
