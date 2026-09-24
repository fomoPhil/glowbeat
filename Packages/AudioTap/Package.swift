// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioTap",
    platforms: [.macOS("14.4")],
    products: [.library(name: "AudioTap", targets: ["AudioTap"])],
    targets: [
        .target(name: "AudioTap"),
        .testTarget(name: "AudioTapTests", dependencies: ["AudioTap"])
    ]
)
