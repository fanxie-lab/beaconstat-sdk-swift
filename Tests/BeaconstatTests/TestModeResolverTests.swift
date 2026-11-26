import XCTest
@testable import Beaconstat

/// `environmentType` is what the handshake reports and the server routes by, so
/// it must agree with `routesToTest` for every input.
final class TestModeResolverTests: XCTestCase {
    private struct Row {
        let mode: TestMode
        let isDebug: Bool, isSimulator: Bool, isTestFlight: Bool, routeTestFlight: Bool
        let environment: String
        let routesToTest: Bool
        let label: String
    }

    private let table: [Row] = [
        Row(mode: .automatic, isDebug: true, isSimulator: false, isTestFlight: false, routeTestFlight: true,
            environment: "development", routesToTest: true, label: "automatic + debug"),
        Row(mode: .automatic, isDebug: false, isSimulator: true, isTestFlight: false, routeTestFlight: true,
            environment: "development", routesToTest: true, label: "automatic + simulator"),
        Row(mode: .automatic, isDebug: false, isSimulator: false, isTestFlight: true, routeTestFlight: true,
            environment: "testflight", routesToTest: true, label: "automatic + TestFlight, routed"),
        Row(mode: .automatic, isDebug: false, isSimulator: false, isTestFlight: true, routeTestFlight: false,
            environment: "production", routesToTest: false, label: "automatic + TestFlight, developer opted out"),
        Row(mode: .forceProduction, isDebug: true, isSimulator: false, isTestFlight: false, routeTestFlight: true,
            environment: "production", routesToTest: false, label: "forceProduction + debug"),
        Row(mode: .forceProduction, isDebug: false, isSimulator: false, isTestFlight: true, routeTestFlight: true,
            environment: "production", routesToTest: false, label: "forceProduction + TestFlight"),
        Row(mode: .forceTest, isDebug: false, isSimulator: false, isTestFlight: false, routeTestFlight: false,
            environment: "development", routesToTest: true, label: "forceTest + App Store"),
        Row(mode: .forceTest, isDebug: false, isSimulator: false, isTestFlight: true, routeTestFlight: true,
            environment: "development", routesToTest: true, label: "forceTest + TestFlight"),
        Row(mode: .automatic, isDebug: false, isSimulator: false, isTestFlight: false, routeTestFlight: true,
            environment: "production", routesToTest: false, label: "automatic + App Store"),
    ]

    func testEnvironmentTypeTable() {
        for r in table {
            XCTAssertEqual(
                TestModeResolver.environmentType(r.mode, isDebug: r.isDebug, isSimulator: r.isSimulator,
                                                 isTestFlight: r.isTestFlight, routeTestFlightToTest: r.routeTestFlight),
                r.environment, r.label)
        }
    }

    func testRoutesToTestAgreesWithTheTable() {
        for r in table {
            XCTAssertEqual(
                TestModeResolver.routesToTest(r.mode, isDebug: r.isDebug, isSimulator: r.isSimulator,
                                              isTestFlight: r.isTestFlight, routeTestFlightToTest: r.routeTestFlight),
                r.routesToTest, r.label)
        }
    }

    /// Every combination: "production" is exactly the not-routed case.
    func testEnvironmentTypeIsConsistentWithRoutesToTestForAllInputs() {
        for mode in [TestMode.automatic, .forceProduction, .forceTest] {
            for bits in 0..<8 {
                let d = bits & 1 != 0, s = bits & 2 != 0, t = bits & 4 != 0
                for route in [true, false] {
                    let env = TestModeResolver.environmentType(mode, isDebug: d, isSimulator: s,
                                                               isTestFlight: t, routeTestFlightToTest: route)
                    let routed = TestModeResolver.routesToTest(mode, isDebug: d, isSimulator: s,
                                                               isTestFlight: t, routeTestFlightToTest: route)
                    XCTAssertEqual(env != "production", routed, "\(mode) d=\(d) s=\(s) t=\(t) route=\(route)")
                }
            }
        }
    }
}
