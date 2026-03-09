// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AkedlyShield",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "AkedlyShield", targets: ["AkedlyShield"])
    ],
    targets: [
        .target(name: "AkedlyShield"),
        .testTarget(name: "AkedlyShieldTests", dependencies: ["AkedlyShield"])
    ]
)
