import Foundation

/// The host's consent decision, held in memory and mirrored to secure storage.
///
/// Two problems made this worth its own type.
///
/// **The getter lagged the setter (M4).** `optOut()` wrote the flag from the
/// core's serial queue while `isOptedOut` read secure storage synchronously on
/// the caller's thread, so `Beaconstat.optOut(); assert(Beaconstat.isOptedOut)`
/// failed intermittently — precisely the check a host writes before showing a
/// "your data collection is off" confirmation. It was also the only place in
/// the SDK that touched `store` off the serial queue.
///
/// **It cost a Keychain round trip per event (M5).** `isOptedOut` is consulted
/// on enqueue, on flush and at every public entry point, so a single `track()`
/// paid for two or more; a SwiftUI settings view reading
/// `Beaconstat.isOptedOut` in its `body` paid for one per re-evaluation, on the
/// main thread.
///
/// So: the decision lives in a lock-protected `Bool` that
/// `record(_:)` updates **synchronously, on the caller's thread**, before the
/// core hops onto its queue. The store is written later, on the queue, by
/// `persist()`. Reads never touch the store once the flag is known.
///
/// The persisted value is loaded by `prime()`, which the core schedules on its
/// serial queue at construction. If the getter is consulted before that lands —
/// possible only in the microseconds after the very first touch of
/// `BeaconstatCore.shared` — it loads the value itself rather than answer wrong.
/// That is at most one read for the life of the process, and every `SecureStore`
/// implementation is internally synchronised, so it is safe wherever it happens.
///
/// The flag is deliberately *not* part of `purgeLocalIdentity()`: it is the
/// consent record, and losing it would silently re-enable collection.
/// `@unchecked Sendable`: `cached` is the only mutable member and every read
/// and write takes `lock`. It is deliberately read off the core's serial queue —
/// that is the whole point of M4 — so it cannot rely on queue confinement the way
/// the rest of the core's state does.
final class OptOutFlag: @unchecked Sendable {
    private let store: SecureStore
    private let lock = NSLock()
    private var cached: Bool?

    init(store: SecureStore) {
        self.store = store
    }

    /// The current decision. Never blocks on storage once known.
    var value: Bool {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        return loadFromStore()
    }

    /// Records a decision made *now*, so the public getter is correct the
    /// instant `optOut()` / `optIn()` returns. Call before hopping onto the
    /// core's queue.
    func record(_ optedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        cached = optedOut
    }

    /// Writes the current decision to secure storage. Call on the core's serial
    /// queue — it is the SDK's only writer of `SecureStoreKey.optedOut`.
    ///
    /// Reads the cache rather than taking a value, so a burst of consent changes
    /// converges on the last one the host actually made instead of on whichever
    /// queued write happened to run last.
    func persist() {
        lock.lock()
        let optedOut = cached ?? false
        lock.unlock()
        store.set(optedOut ? "1" : nil, forKey: .optedOut)
    }

    /// Loads the persisted decision if the host hasn't made one this launch.
    /// Scheduled on the core's serial queue so the read is off the caller's
    /// thread; a no-op once the flag is known.
    func prime() {
        lock.lock()
        let known = cached != nil
        lock.unlock()
        guard !known else { return }
        _ = loadFromStore()
    }

    private func loadFromStore() -> Bool {
        // Outside the lock: `store` may be the Keychain, and holding a lock
        // across that would serialise every reader behind one round trip.
        let persisted = store.string(forKey: .optedOut) != nil
        lock.lock(); defer { lock.unlock() }
        // A decision recorded while the read was in flight is newer than the
        // stored one and wins.
        if let cached { return cached }
        cached = persisted
        return persisted
    }
}
