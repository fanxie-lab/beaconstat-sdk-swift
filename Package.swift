// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Beaconstat",
    // Declared to match what the README and CHANGELOG advertise and what the
    // code actually contains (L9). Only iOS and macOS were declared, so tvOS,
    // watchOS and visionOS silently inherited the toolchain's *default*
    // deployment target rather than the advertised minimum — and none of them
    // was in CI, which is how watchOS shipped 1.0.0 with no lifecycle events at
    // all.
    //
    // watchOS 8 rather than 7: `WKExtension.applicationDidEnterBackgroundNotification`
    // needs 7, but 8 is what the README promises and it lets
    // `LifecycleObserver.transitions()` drop a runtime `#available` check that
    // can no longer fail.
    //
    // Every one of these is built in CI, per platform, in Release.
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Beaconstat",
            targets: ["Beaconstat"]
        ),
    ],
    targets: [
        .target(
            name: "Beaconstat"
        ),
        .testTarget(
            name: "BeaconstatTests",
            dependencies: ["Beaconstat"]
        ),
    ]
)
