import Foundation

/// Exponential backoff schedule for flush retries.
enum RetryPolicy {
    /// Delay before `attempt` (1-based). Returns nil when out of range
    /// (`attempt < 1` or `attempt > maxRetries`) meaning "stop retrying now".
    static func delay(forAttempt attempt: Int, maxRetries: Int,
                      base: TimeInterval = 2, cap: TimeInterval = 30) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxRetries else { return nil }
        return Swift.min(pow(base, Double(attempt)), cap)
    }
}
