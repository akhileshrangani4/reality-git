// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RealityGitServer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RealityGitServer", targets: ["RealityGitServer"])],
    dependencies: [
        .package(path: "../Packages/RealityGitCore"),
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.121.4")
    ],
    targets: [
        .executableTarget(name: "RealityGitServer", dependencies: [
            "RealityGitCore",
            .product(name: "Vapor", package: "vapor")
        ]),
        .testTarget(name: "RealityGitServerTests", dependencies: [
            "RealityGitServer",
            "RealityGitCore",
            .product(name: "XCTVapor", package: "vapor")
        ])
    ]
)
