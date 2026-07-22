import Foundation

/// Time source with a server-skew correction. Injectable for tests.
protocol Clock: AnyObject {
    func now() -> Date
    func nowISO8601() -> String
    func iso8601(_ date: Date) -> String
    func applyServerTime(_ iso: String)
}

final class SystemClock: Clock {
    private let lock = NSLock()
    private var skew: TimeInterval = 0            // serverTime - deviceTime
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = { Date() }) {
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

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
