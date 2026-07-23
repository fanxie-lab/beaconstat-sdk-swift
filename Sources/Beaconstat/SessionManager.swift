import Foundation

struct SessionStart {
    let id: String
    let isFirst: Bool
    let previousAt: String?
}

/// Owns session identity + the inactivity-timeout rule. Not thread-safe — the
/// core touches it only on its serial queue. A fresh process (new instance)
/// with no in-memory session always starts a new one.
final class SessionManager {
    private let store: SecureStore
    private let clock: Clock
    private let timeout: TimeInterval

    private var sessionId: String?
    private var lastActivity: Date?

    init(store: SecureStore, clock: Clock, timeout: TimeInterval) {
        self.store = store
        self.clock = clock
        self.timeout = timeout
    }

    func currentSessionId() -> String? { sessionId }

    /// Starts a new session on cold start or after the inactivity timeout;
    /// otherwise refreshes last-activity and returns nil.
    func startIfNeeded() -> SessionStart? {
        let now = clock.now()
        if let last = lastActivity, sessionId != nil, now.timeIntervalSince(last) <= timeout {
            lastActivity = now
            return nil
        }
        // New session.
        let previousAt = store.string(forKey: .lastSessionStartedAt)
        let isFirst = store.string(forKey: .hasStartedSession) == nil
        let id = UUID().uuidString
        sessionId = id
        lastActivity = now
        let startedAtISO = clock.iso8601(now)
        store.set(startedAtISO, forKey: .lastSessionStartedAt)
        store.set("1", forKey: .hasStartedSession)
        return SessionStart(id: id, isFirst: isFirst, previousAt: isFirst ? nil : previousAt)
    }
}
