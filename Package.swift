// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacEverything",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EverythingCore", targets: ["EverythingCore"]),
        .executable(name: "ev", targets: ["ev"]),
        .executable(name: "everythingd", targets: ["everythingd"]),
        .executable(name: "EverythingApp", targets: ["EverythingApp"]),
    ],
    targets: [
        .target(name: "EverythingCore"),
        .executableTarget(name: "ev", dependencies: ["EverythingCore"]),
        .executableTarget(name: "everythingd", dependencies: ["EverythingCore"]),
        .executableTarget(name: "EverythingApp", dependencies: ["EverythingCore"]),
        .testTarget(name: "EverythingCoreTests", dependencies: ["EverythingCore"]),
    ]
)
