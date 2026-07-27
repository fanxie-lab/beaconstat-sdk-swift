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
final class LifecycleObserver {
    /// The app has actually left the foreground. The core emits
    /// `_bcs.apple.app_backgrounded` and (by default) flushes.
    var onBackground: (() -> Void)?
    /// The app merely lost focus — macOS only. The core flushes and emits
    /// nothing.
    var onResignActive: (() -> Void)?
    /// The app is frontmost again. The core resumes/starts a session.
    var onForeground: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []

    /// Whether OS notifications are currently subscribed. `optOut()` and
    /// `shutdown()` must leave this `false` — the observers used to stay
    /// registered for the app's lifetime (M14).
    var isObserving: Bool { !tokens.isEmpty }

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
        if #available(watchOS 7.0, *) {
            return [
                (WKExtension.applicationDidEnterBackgroundNotification, .background),
                (WKExtension.applicationWillEnterForegroundNotification, .foreground),
            ]
        }
        // watchOS 6 and earlier expose no lifecycle notifications, only
        // `WKExtensionDelegate` callbacks the SDK cannot reach from a library.
        return []
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
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
    }

    private func observe(_ name: Notification.Name, _ center: NotificationCenter, _ handler: @escaping () -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() })
    }

    deinit { stop() }
}
