import Foundation

/// Resolves whether a run routes to the test endpoint (`/v1/debug/events`).
/// Covers DEBUG/simulator + TestFlight (opt-in) + the explicit force modes.
enum TestModeResolver {
    static func routesToTest(_ mode: TestMode, isDebug: Bool, isSimulator: Bool,
                             isTestFlight: Bool, routeTestFlightToTest: Bool) -> Bool {
        switch mode {
        case .forceProduction: return false
        case .forceTest: return true
        case .automatic: return isDebug || isSimulator || (isTestFlight && routeTestFlightToTest)
        }
    }
}
