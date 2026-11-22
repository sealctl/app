// swift-tools-version:6.0
// The generated UniFFI Swift for sealctl-core and sealctl-app, over SealctlFFI.xcframework
// (built by scripts/build-core-ios.sh; SPEC.md 4, 5.3).
import PackageDescription

let package = Package(
    name: "SealCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SealCore", targets: ["SealCore"])],
    targets: [
        .binaryTarget(name: "SealctlFFI", path: "SealctlFFI.xcframework"),
        .target(
            name: "SealCore",
            dependencies: ["SealctlFFI"],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration")]
        ),
        .testTarget(name: "SealCoreTests", dependencies: ["SealCore"], resources: [.copy("Vectors")]),
    ]
)
