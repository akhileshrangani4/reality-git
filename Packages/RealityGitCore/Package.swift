// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RealityGitCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "RealityGitCore", targets: ["RealityGitCore"])],
    targets: [
        .target(name: "RealityGitCore"),
        .testTarget(name: "RealityGitCoreTests", dependencies: ["RealityGitCore"])
    ]
)
