// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JacclClusterKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JacclClusterKit", targets: ["JacclClusterKit"])
    ],
    targets: [
        .target(
            name: "JacclClusterKit"
        ),
        .testTarget(
            name: "JacclClusterKitTests",
            dependencies: ["JacclClusterKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
