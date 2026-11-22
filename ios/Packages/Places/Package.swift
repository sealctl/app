// swift-tools-version:6.0
// Region monitoring with CLMonitor and one location fix per first approval (SPEC.md 10.3, 11.9).
import PackageDescription

let package = Package(
    name: "Places",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Places", targets: ["Places"])],
    targets: [.target(name: "Places")]
)
