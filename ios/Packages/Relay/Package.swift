// swift-tools-version:6.0
// The Relay API client: signed HTTP, the phone socket, retries (SPEC.md 8).
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Relay", targets: ["Relay"])],
    dependencies: [.package(path: "../SealCore")],
    targets: [
        .target(name: "Relay", dependencies: ["SealCore"]),
        .testTarget(name: "RelayTests", dependencies: ["Relay", "SealCore"]),
    ]
)
