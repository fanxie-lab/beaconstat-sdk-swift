import Foundation

/// Resolves whether a run routes to the test endpoint (`/v1/debug/events`), and
/// which environment the handshake reports for it.
/// Covers DEBUG/simulator + TestFlight (on by default) + the explicit force modes.
enum TestModeResolver {
    static func routesToTest(_ mode: TestMode, isDebug: Bool, isSimulator: Bool,
                             isTestFlight: Bool, routeTestFlightToTest: Bool) -> Bool {
        switch mode {
        case .forceProduction: return false
        case .forceTest: return true
        case .automatic: return isDebug || isSimulator || (isTestFlight && routeTestFlightToTest)
        }
    }

    /// The `environmentType` sent at handshake — `"development"`, `"testflight"`
    /// or `"production"`. The server routes by this value (SDK >= 1.2.0), so it
    /// is derived from the same inputs as `routesToTest` and is `"production"`
    /// exactly when `routesToTest` is false.
    ///
    /// `"testflight"` is reported only for an automatic-mode TestFlight run that
    /// is not DEBUG/simulator; any other test-routed run is `"development"`.
    static func environmentType(_ mode: TestMode, isDebug: Bool, isSimulator: Bool,
                                isTestFlight: Bool, routeTestFlightToTest: Bool) -> String {
        guard routesToTest(mode, isDebug: isDebug, isSimulator: isSimulator,
                           isTestFlight: isTestFlight, routeTestFlightToTest: routeTestFlightToTest)
        else { return "production" }
        if mode == .automatic, !isDebug, !isSimulator { return "testflight" }
        return "development"
    }
}
