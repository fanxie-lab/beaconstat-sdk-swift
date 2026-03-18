// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Beaconstat",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
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
