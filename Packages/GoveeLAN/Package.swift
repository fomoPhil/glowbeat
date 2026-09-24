// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoveeLAN",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "GoveeLAN", targets: ["GoveeLAN"]),
        .library(name: "GoveeLANTestSupport", targets: ["GoveeLANTestSupport"])
    ],
    targets: [
        .target(name: "GoveeLAN"),
        .target(name: "GoveeLANTestSupport", dependencies: ["GoveeLAN"]),
        .testTarget(name: "GoveeLANTests", dependencies: ["GoveeLAN", "GoveeLANTestSupport"])
    ]
)
