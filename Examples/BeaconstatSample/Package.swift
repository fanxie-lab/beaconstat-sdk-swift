// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BeaconstatSample",
    platforms: [.iOS(.v15), .macOS(.v13)],
    dependencies: [
        .package(path: "../..")   // the Beaconstat SDK
    ],
    targets: [
        .executableTarget(
            name: "BeaconstatSample",
            dependencies: [.product(name: "Beaconstat", package: "sdk-swift")]
        )
    ]
)
