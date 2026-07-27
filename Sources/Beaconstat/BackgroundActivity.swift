import Foundation

/// Keeps the process alive long enough for a background flush to finish.
///
/// Without an assertion, iOS suspends roughly 5 seconds after
/// `didEnterBackground`. That is the exact moment `flushOnBackground` (on by
/// default) starts a POST, so on a slow link the request was routinely cut off
/// mid-flight (H2).
///
/// The assertion narrows that window; it does not close it. What closes it is
/// the queue's mark-in-flight/delete-on-ack model, which replays an
/// unacknowledged batch after termination. Treat this as an optimisation that
/// buys the *current* attempt a chance to land.
protocol BackgroundActivity: AnyObject, Sendable {
    /// Takes an assertion. Idempotent: a second call while one is held does
    /// nothing. `expiration` fires if the OS reclaims the time before `end()`.
    ///
    /// Safe to call from any thread — the core takes the assertion on the
    /// notification thread, before hopping onto its serial queue, because the
    /// OS clock starts at the notification and the hop is pure latency.
    func begin(expiration: @escaping @Sendable () -> Void)
    /// Releases the assertion. Idempotent.
    func end()
}

/// No-op for platforms that don't suspend apps this way (macOS) and for any
/// build where the API isn't available.
final class NoBackgroundActivity: BackgroundActivity {
    func begin(expiration: @escaping @Sendable () -> Void) {}
    func end() {}
}

#if os(iOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)

/// `ProcessInfo.performExpiringActivity` rather than
/// `UIApplication.beginBackgroundTask`.
///
/// Both hold off suspension. This one is Foundation-only, so it needs no UIKit
/// import, no main-thread hop to reach `UIApplication.shared`, and — the
/// deciding factor — it is available to **app extensions**. The SDK ships push
/// and widget entry points and a Keychain access group specifically so a
/// `UNNotificationServiceExtension` can call it (M12); referencing
/// `UIApplication.shared` from a target built with
/// `APPLICATION_EXTENSION_API_ONLY` is exactly what those adopters cannot do.
///
/// The system holds the process while the supplied block is executing, so the
/// block parks on a semaphore until `end()` signals it.
/// `@unchecked Sendable`: `held` and `release` are the mutable members and both
/// are read and written under `lock`. It has to be safe from any thread — the
/// core takes the assertion on the notification-delivery thread, before hopping
/// onto its serial queue, precisely because the OS suspension clock starts at
/// the notification (H2).
final class ExpiringBackgroundActivity: BackgroundActivity, @unchecked Sendable {
    private let reason: String
    /// Backstop so a lost `end()` can't park a system thread indefinitely. The
    /// OS budget is shorter than this in practice; whichever fires first wins.
    private let maximumHold: TimeInterval
    private let lock = NSLock()
    private var held = false
    private var release = DispatchSemaphore(value: 0)

    init(reason: String = "com.beaconstat.sdk.flush", maximumHold: TimeInterval = 20) {
        self.reason = reason
        self.maximumHold = maximumHold
    }

    func begin(expiration: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !held else { lock.unlock(); return }
        held = true
        release = DispatchSemaphore(value: 0)
        let signal = release
        lock.unlock()

        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [weak self] expired in
            guard let self else { return }
            guard !expired else {
                // The OS wants the process back. Wake the holding block and let
                // the core know the flush won't finish — the batch is still
                // queued on disk, so it replays rather than being lost.
                expiration()
                signal.signal()
                return
            }
            // Returning from here releases the assertion, so park until the
            // flush completes.
            _ = signal.wait(timeout: .now() + self.maximumHold)
            self.clear(signal)
        }
    }

    func end() {
        lock.lock()
        let signal = release
        let wasHeld = held
        lock.unlock()
        guard wasHeld else { return }
        signal.signal()
    }

    /// Only clears state if this is still the *current* assertion — a stale
    /// block finishing late must not unlock a newer one.
    private func clear(_ signal: DispatchSemaphore) {
        lock.lock(); defer { lock.unlock() }
        guard release === signal else { return }
        held = false
    }
}

#endif

enum BackgroundActivityFactory {
    static func make() -> BackgroundActivity {
        #if os(iOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)
        return ExpiringBackgroundActivity()
        #else
        return NoBackgroundActivity()
        #endif
    }
}
