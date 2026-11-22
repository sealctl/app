// swift-tools-version:6.0
// Keychain items and LocalAuthentication (SPEC.md 7.2, 9.6).
import PackageDescription

let package = Package(
    name: "Vault",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Vault", targets: ["Vault"])],
    dependencies: [.package(path: "../SealCore")],
    targets: [
        .target(name: "Vault", dependencies: ["SealCore"]),
        .testTarget(name: "VaultTests", dependencies: ["Vault", "SealCore"]),
    ]
)
