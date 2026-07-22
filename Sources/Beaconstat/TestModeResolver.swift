import Foundation

/// Resolves whether a run routes to the test endpoint (`/v1/debug/events`).
/// M7 later folds in TestFlight; this covers DEBUG/simulator + the explicit modes.
enum TestModeResolver {
    static func routesToTest(_ mode: TestMode, isDebug: Bool, isSimulator: Bool) -> Bool {
        switch mode {
        case .forceProduction: return false
        case .forceTest: return true
        case .automatic: return isDebug || isSimulator
        }
    }
}
