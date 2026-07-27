import Foundation

struct SessionStart: Sendable {
    let id: String
    let isFirst: Bool
    let previousAt: String?
}

/// Owns session identity + the inactivity-timeout rule. Not thread-safe — the
/// core touches it only on its serial queue. A fresh process (new instance)
/// with no in-memory session always starts a new one.
/// `@unchecked Sendable`, and unlike the stores in `SecureStore.swift` this
/// one holds **no lock**: it is queue-confined. Every method is called from the
/// core's serial queue and from nowhere else. The annotation records that
/// promise; `ConcurrencySoakTests` is what keeps it honest, by driving the core
/// from eight threads and checking the session bookkeeping still balances.
final class SessionManager: @unchecked Sendable {
    private let store: SecureStore
    private let clock: Clock
    private var timeout: TimeInterval

    private var sessionId: String?
    private var lastActivity: Date?

    init(store: SecureStore, clock: Clock, timeout: TimeInterval) {
        self.store = store
        self.clock = clock
        self.timeout = timeout
    }

    func currentSessionId() -> String? { sessionId }

    /// Applies a new inactivity window on reconfigure, without ending the
    /// current session. Before this, a second `configure()` silently kept the
    /// original `sessionTimeout` (M7).
    func setTimeout(_ newValue: TimeInterval) { timeout = newValue }

    /// Forgets the in-memory session so the next `startIfNeeded()` begins a
    /// fresh one. Used by `optOut()`'s local identity purge (M14).
    func reset() {
        sessionId = nil
        lastActivity = nil
    }

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
