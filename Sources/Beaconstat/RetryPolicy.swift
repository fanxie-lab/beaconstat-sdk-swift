import Foundation

/// Backoff schedule for flush retries.
enum RetryPolicy {
    /// Ceiling on the exponential term.
    static let cap: TimeInterval = 30

    /// Server-supplied `Retry-After` values above this are treated as this. A
    /// broken or hostile `Retry-After: 999999` must not park the SDK for
    /// eleven days.
    static let maxRetryAfter: TimeInterval = 900

    /// How long to wait before starting a fresh round once the attempt budget
    /// is spent (M9).
    ///
    /// The old code reset `retryCount` and left a comment saying the periodic
    /// timer would retry — but in Release `flushInterval` is **14,400 s**, so a
    /// queue could sit for four hours after fourteen seconds of trying, with
    /// the 500-event cap evicting underneath it the whole time.
    static let exhaustedRoundDelay: TimeInterval = 300

    /// Delay before `attempt` (1-based), or `nil` when the attempt budget is
    /// spent (`attempt < 1` or `attempt > maxRetries`).
    ///
    /// - Parameters:
    ///   - retryAfter: a parsed `Retry-After`. Honoured over the schedule —
    ///     the server knows more about its own recovery than we do — clamped to
    ///     `maxRetryAfter` and still jittered.
    ///   - randomizer: injectable for deterministic tests.
    static func delay(forAttempt attempt: Int, maxRetries: Int,
                      base: TimeInterval = 2, cap: TimeInterval = RetryPolicy.cap,
                      retryAfter: TimeInterval? = nil,
                      randomizer: (ClosedRange<TimeInterval>) -> TimeInterval = {
                          Double.random(in: $0)
                      }) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxRetries else { return nil }
        if let retryAfter, retryAfter > 0 {
            let honoured = Swift.min(retryAfter, maxRetryAfter)
            // Spread even a server-set delay: a fleet all told "60" would
            // otherwise come back in one spike, which is the problem
            // `Retry-After` exists to solve.
            return honoured + randomizer(0...Swift.min(honoured * 0.2, 10))
        }
        // Equal jitter: half the backoff, plus a random half. Keeps the useful
        // growth of exponential backoff while spreading a recovering server's
        // thundering herd across a window as wide as the delay itself. Full
        // jitter would permit a near-zero first retry, which is exactly the
        // wrong thing to do to a server that has just come back.
        let ceiling = Swift.min(pow(base, Double(attempt)), cap)
        return ceiling / 2 + randomizer(0...(ceiling / 2))
    }

    /// Jittered delay before the next round, never longer than the host's own
    /// flush interval.
    static func exhaustedRoundDelay(cappedBy flushInterval: TimeInterval,
                                    randomizer: (ClosedRange<TimeInterval>) -> TimeInterval = {
                                        Double.random(in: $0)
                                    }) -> TimeInterval {
        let ceiling = Swift.min(exhaustedRoundDelay, Swift.max(1, flushInterval))
        return ceiling / 2 + randomizer(0...(ceiling / 2))
    }
}

/// Parser for the `Retry-After` response header, which `Transport` used to
/// discard along with the whole of `allHeaderFields` (M9).
enum RetryAfter {
    /// RFC 9110 allows both forms. `Locale(identifier: "en_US_POSIX")` is
    /// mandatory: a device set to a non-Gregorian calendar or a locale with
    /// different month abbreviations would otherwise fail to parse a perfectly
    /// valid header.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Seconds to wait, or `nil` if the header is absent or unparseable.
    /// Never negative: a date already in the past means "now".
    static func parse(_ value: String?, now: Date) -> TimeInterval? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        // delta-seconds. Integer-only on purpose — `Double("NaN")` succeeds and
        // would poison every subsequent comparison.
        if let seconds = Int(trimmed) {
            return TimeInterval(Swift.max(0, seconds))
        }
        if let date = httpDateFormatter.date(from: trimmed) {
            return Swift.max(0, date.timeIntervalSince(now))
        }
        return nil
    }
}
