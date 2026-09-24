// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Effects",
    platforms: [.macOS("14.4")],
    products: [.library(name: "Effects", targets: ["Effects"])],
    targets: [
        .target(name: "Effects"),
        .testTarget(name: "EffectsTests", dependencies: ["Effects"])
    ]
)
