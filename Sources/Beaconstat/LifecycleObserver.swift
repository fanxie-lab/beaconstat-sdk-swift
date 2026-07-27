import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Subscribes to OS active/background transitions. Callbacks fire on the
/// notification-delivery thread; the core re-hops them onto its serial queue.
final class LifecycleObserver {
    var onBackground: (() -> Void)?
    var onForeground: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    /// Whether OS notifications are currently subscribed. `optOut()` and
    /// `shutdown()` must leave this `false` — the observers used to stay
    /// registered for the app's lifetime (M14).
    var isObserving: Bool { !tokens.isEmpty }

    func start() {
        let center = NotificationCenter.default
        #if canImport(UIKit) && !os(watchOS)
        observe(UIApplication.didEnterBackgroundNotification, center) { [weak self] in self?.onBackground?() }
        observe(UIApplication.willEnterForegroundNotification, center) { [weak self] in self?.onForeground?() }
        #elseif os(macOS)
        observe(NSApplication.didResignActiveNotification, center) { [weak self] in self?.onBackground?() }
        observe(NSApplication.didBecomeActiveNotification, center) { [weak self] in self?.onForeground?() }
        #endif
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
