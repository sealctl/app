// swift-tools-version:6.0
// The app model over the Rust rules and store (SPEC.md 6.3). `EngineKit` is the read-only
// part the Notification Service Extension links: wording, the extension snapshot and the
// request notification content.
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "EngineKit", targets: ["EngineKit"]),
    ],
    dependencies: [
        .package(path: "../SealCore"),
        .package(path: "../Vault"),
        .package(path: "../Relay"),
        .package(path: "../Places"),
    ],
    targets: [
        .target(name: "EngineKit", dependencies: ["SealCore", "Vault", "Relay"]),
        .target(name: "Engine", dependencies: ["EngineKit", "SealCore", "Vault", "Relay", "Places"]),
        .testTarget(name: "EngineTests", dependencies: ["Engine", "EngineKit", "SealCore", "Vault", "Relay"]),
    ]
)
