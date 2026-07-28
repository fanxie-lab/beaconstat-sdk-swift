import XCTest
// `UIKit` and `AppKit` arrive transitively through `XCTest`, so the iOS and
// macOS branches below compiled without an explicit import. `WatchKit` does
// not, so `testWatchKitMapsEnterBackgroundAndEnterForeground` never built —
// the whole test target failed to compile for watchOS, which is why CI's
// watchOS `Test on a simulator` leg could not have been passing and L9's
// "watchOS now emits lifecycle events" was verified only by reading the source.
#if os(watchOS)
import WatchKit
#endif
@testable import Beaconstat

/// M3 — macOS mapped `app_backgrounded` onto `NSApplication.didResignActive`,
/// which fires on ⌘-Tab, on clicking another window and on Mission Control. A
/// Mac user switching apps 200×/day therefore produced 200 `app_backgrounded`
/// events on a reserved dimension whose iOS meaning is completely different.
///
/// L9 — watchOS had no lifecycle events at all: the UIKit branch excluded it and
/// the AppKit branch didn't match, so neither `app_backgrounded` nor foreground
/// session resume ever fired there.
final class LifecycleObserverTests: XCTestCase {
    private func fired(_ observer: LifecycleObserver,
                       posting name: Notification.Name) -> LifecycleObserver.Transition? {
        var seen: LifecycleObserver.Transition?
        observer.onBackground = { seen = .background }
        observer.onResignActive = { seen = .resignActive }
        observer.onForeground = { seen = .foreground }
        NotificationCenter.default.post(name: name, object: nil)
        return seen
    }

    /// Every platform the README advertises must observe *something*, or an
    /// entire platform silently stops reporting sessions. This is the assertion
    /// watchOS failed.
    func testEveryPlatformObservesAtLeastABackgroundAndAForegroundTransition() {
        let transitions = LifecycleObserver.transitions()
        XCTAssertTrue(transitions.contains { $0.transition == .background },
                      "no background transition on \(EnvironmentCollector.platform)")
        XCTAssertTrue(transitions.contains { $0.transition == .foreground },
                      "no foreground transition on \(EnvironmentCollector.platform)")
    }

    func testStartSubscribesAndStopUnsubscribes() {
        let observer = LifecycleObserver()
        XCTAssertFalse(observer.isObserving)
        observer.start()
        XCTAssertTrue(observer.isObserving)
        observer.stop()
        XCTAssertFalse(observer.isObserving)
    }

    // MARK: - platform mappings

    #if canImport(UIKit) && !os(watchOS)
    func testUIKitMapsEnterBackgroundAndEnterForeground() {
        let observer = LifecycleObserver()
        observer.start(); defer { observer.stop() }
        XCTAssertEqual(fired(observer, posting: UIApplication.didEnterBackgroundNotification), .background)
        XCTAssertEqual(fired(observer, posting: UIApplication.willEnterForegroundNotification), .foreground)
    }
    #endif

    #if os(macOS)
    /// The finding itself: losing focus is not backgrounding.
    func testMacResignActiveIsNotABackgroundTransition() {
        let observer = LifecycleObserver()
        observer.start(); defer { observer.stop() }
        XCTAssertEqual(fired(observer, posting: NSApplication.didResignActiveNotification),
                       .resignActive,
                       "⌘-Tab must not be reported as backgrounding")
    }

    /// The two points where a Mac user is genuinely finished with the app.
    func testMacHideAndTerminateAreBackgroundTransitions() {
        let observer = LifecycleObserver()
        observer.start(); defer { observer.stop() }
        XCTAssertEqual(fired(observer, posting: NSApplication.didHideNotification), .background)
        XCTAssertEqual(fired(observer, posting: NSApplication.willTerminateNotification), .background)
    }

    func testMacBecomeActiveIsAForegroundTransition() {
        let observer = LifecycleObserver()
        observer.start(); defer { observer.stop() }
        XCTAssertEqual(fired(observer, posting: NSApplication.didBecomeActiveNotification), .foreground)
    }
    #endif

    #if os(watchOS)
    // No `@available(watchOS 7.0, *)`: the package declares watchOS 8 (L9).
    func testWatchKitMapsEnterBackgroundAndEnterForeground() {
        let observer = LifecycleObserver()
        observer.start(); defer { observer.stop() }
        XCTAssertEqual(fired(observer, posting: WKExtension.applicationDidEnterBackgroundNotification),
                       .background)
        XCTAssertEqual(fired(observer, posting: WKExtension.applicationWillEnterForegroundNotification),
                       .foreground)
    }
    #endif
}
