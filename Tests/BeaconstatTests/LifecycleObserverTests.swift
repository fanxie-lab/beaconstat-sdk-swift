import XCTest
@testable import Beaconstat

final class LifecycleObserverTests: XCTestCase {
    func testPostingBackgroundNotificationFiresCallback() {
        let observer = LifecycleObserver()
        var backgrounded = false
        observer.onBackground = { backgrounded = true }
        observer.start(); defer { observer.stop() }
        // macOS host: NSApplication.didResignActive; iOS: UIApplication.didEnterBackground.
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #elseif os(macOS)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #endif
        XCTAssertTrue(backgrounded)
    }

    func testPostingForegroundNotificationFiresCallback() {
        let observer = LifecycleObserver()
        var foregrounded = false
        observer.onForeground = { foregrounded = true }
        observer.start(); defer { observer.stop() }
        // macOS host: NSApplication.didBecomeActive; iOS: UIApplication.willEnterForeground.
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #elseif os(macOS)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #endif
        XCTAssertTrue(foregrounded)
    }
}
