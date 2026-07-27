import Foundation

/// Time source with a server-skew correction. Injectable for tests.
///
/// `Sendable` because the core hands it to `SessionManager` and reads it from
/// closures that cross concurrency domains. Conformers are responsible for their
/// own synchronisation — `SystemClock` locks its skew (M13).
protocol Clock: AnyObject, Sendable {
    func now() -> Date
    func nowISO8601() -> String
    func iso8601(_ date: Date) -> String
    func applyServerTime(_ iso: String)
}

/// `@unchecked Sendable`, and the "unchecked" part is exactly two things: `skew`
/// is mutable but only ever read or written under `lock`, and `dateProvider` is
/// an immutable `@Sendable` closure. There is no third piece of state.
final class SystemClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var skew: TimeInterval = 0            // serverTime - deviceTime
    private let dateProvider: @Sendable () -> Date

    init(dateProvider: @escaping @Sendable () -> Date = { Date() }) {
        self.dateProvider = dateProvider
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return dateProvider().addingTimeInterval(skew)
    }

    func nowISO8601() -> String { iso8601(now()) }

    func iso8601(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }

    func applyServerTime(_ iso: String) {
        guard let serverDate = Self.formatter.date(from: iso) else { return }
        lock.lock(); defer { lock.unlock() }
        skew = serverDate.timeIntervalSince(dateProvider())
    }

    /// `nonisolated(unsafe)` rather than a fresh formatter per call, or an
    /// instance property, or a lock.
    ///
    /// `ISO8601DateFormatter` is not `Sendable`, so Swift 6 rejects it as a
    /// shared static (M13). It is, however, documented as safe to use from
    /// multiple threads once configured, and this one is configured exactly once
    /// in this initialiser and never mutated again — `formatOptions` and
    /// `timeZone` are set here and nowhere else in the SDK.
    ///
    /// The alternatives are worse. Constructing a formatter per call would put
    /// an allocation and an ICU setup on `nowISO8601()`, which runs on the
    /// enqueue path for every single event. Serialising it behind the existing
    /// `lock` would make every timestamp contend with every other, for no
    /// safety the class does not already have.
    ///
    /// `ConcurrentClockTests` hammers this from eight threads, so a future swap
    /// to a formatter that genuinely is not thread-safe fails a test rather than
    /// corrupting timestamps in the field.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
