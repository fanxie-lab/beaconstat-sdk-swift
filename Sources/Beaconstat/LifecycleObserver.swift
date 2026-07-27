import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if os(watchOS)
import WatchKit
#endif

/// Subscribes to OS foreground/background transitions. Callbacks fire on the
/// notification-delivery thread; the core re-hops them onto its serial queue.
///
/// The three transitions are deliberately distinct, because "the app went to
/// the background" does not mean the same thing on every Apple platform:
///
/// - **iOS / iPadOS / tvOS / visionOS / Mac Catalyst** — `didEnterBackground`
///   and `willEnterForeground` are exactly the intended semantics.
/// - **macOS** — the observer used to map `background` onto
///   `didResignActive`, which fires on ⌘-Tab, on clicking another window and on
///   Mission Control. A Mac user switching apps 200 times a day produced 200
///   `_bcs.apple.app_backgrounded` events and 200 POSTs, and the dimension was
///   not comparable with iOS at all (M3). A Mac app that loses focus is still
///   running. So resign-active is now its own `resignActive` transition, which
///   the core uses to *flush* and nothing else, and `background` is reserved for
///   `didHide` (⌘H) and `willTerminate` (quit) — the two points where the user
///   really has finished with the app.
/// - **watchOS** — previously had *no* lifecycle events at all: the UIKit branch
///   excluded it (`canImport(UIKit) && !os(watchOS)`) and the AppKit branch
///   didn't match, so `app_backgrounded` and foreground session resume silently
///   never fired (L9). WatchKit's equivalents are wired up here.
///
/// `willTerminate` is best-effort by nature: the core hops onto its serial
/// queue, and the process may exit before that block runs. It costs nothing to
/// try, and Wave 2's mark-in-flight/delete-on-ack queue means an interrupted
/// flush replays rather than loses.
/// `@unchecked Sendable`: `tokens` and the three callbacks are mutable, and all
/// six accesses take `lock`. A lock rather than queue confinement because the
/// callbacks are *assigned* from the core's serial queue but *invoked* from
/// whichever thread `NotificationCenter` delivers on.
final class LifecycleObserver: @unchecked Sendable {
    private let lock = NSLock()
    /// The app has actually left the foreground. The core emits
    /// `_bcs.apple.app_backgrounded` and (by default) flushes.
    var onBackground: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onBackground }
        set { lock.lock(); _onBackground = newValue; lock.unlock() }
    }
    private var _onBackground: (@Sendable () -> Void)?
    /// The app merely lost focus — macOS only. The core flushes and emits
    /// nothing.
    var onResignActive: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onResignActive }
        set { lock.lock(); _onResignActive = newValue; lock.unlock() }
    }
    private var _onResignActive: (@Sendable () -> Void)?
    /// The app is frontmost again. The core resumes/starts a session.
    var onForeground: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onForeground }
        set { lock.lock(); _onForeground = newValue; lock.unlock() }
    }
    private var _onForeground: (@Sendable () -> Void)?

    private var tokens: [NSObjectProtocol] = []

    /// Whether OS notifications are currently subscribed. `optOut()` and
    /// `shutdown()` must leave this `false` — the observers used to stay
    /// registered for the app's lifetime (M14).
    var isObserving: Bool {
        lock.lock(); defer { lock.unlock() }
        return !tokens.isEmpty
    }

    enum Transition {
        case background
        case resignActive
        case foreground
    }

    /// The notifications this platform maps onto each transition.
    ///
    /// Exposed so a test can pin the mapping per platform rather than only the
    /// callback plumbing — the macOS mis-mapping in M3 and the missing watchOS
    /// branch in L9 were both mapping bugs, invisible to a test that just posts
    /// whichever notification the code happens to observe.
    static func transitions() -> [(name: Notification.Name, transition: Transition)] {
        #if canImport(UIKit) && !os(watchOS)
        return [
            (UIApplication.didEnterBackgroundNotification, .background),
            (UIApplication.willEnterForegroundNotification, .foreground),
        ]
        #elseif os(macOS)
        return [
            // Quitting and hiding are the real "user is done" signals.
            (NSApplication.willTerminateNotification, .background),
            (NSApplication.didHideNotification, .background),
            // Losing focus is not. Flush, but do not report it as a transition.
            (NSApplication.didResignActiveNotification, .resignActive),
            (NSApplication.didBecomeActiveNotification, .foreground),
        ]
        #elseif os(watchOS)
        // No `#available(watchOS 7.0, *)`: `Package.swift` now declares
        // `.watchOS(.v8)` (L9), so the check could never fail — and its
        // `return []` fallback was worse than dead code. A platform that returns
        // no transitions has no `app_backgrounded` and no foreground session
        // resume, silently, which is exactly the bug L9 describes. Removing the
        // branch removes the only way `transitions()` can be empty on a declared
        // platform, and `LifecycleObserverTests` asserts that per platform.
        return [
            (WKExtension.applicationDidEnterBackgroundNotification, .background),
            (WKExtension.applicationWillEnterForegroundNotification, .foreground),
        ]
        #else
        return []
        #endif
    }

    func start() {
        let center = NotificationCenter.default
        for (name, transition) in Self.transitions() {
            observe(name, center) { [weak self] in
                guard let self else { return }
                switch transition {
                case .background: self.onBackground?()
                case .resignActive: self.onResignActive?()
                case .foreground: self.onForeground?()
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let observed = tokens
        tokens = []
        lock.unlock()
        observed.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func observe(_ name: Notification.Name, _ center: NotificationCenter,
                         _ handler: @escaping @Sendable () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
        lock.lock(); tokens.append(token); lock.unlock()
    }

    deinit { stop() }
}
