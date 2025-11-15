// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ArkavoKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ArkavoKit",
            targets: ["ArkavoKit"]
        ),
        .library(
            name: "ArkavoC2PA",
            targets: ["ArkavoC2PA"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/arkavo-org/OpenTDFKit", branch: "main")
    ],
    targets: [
        .target(
            name: "ArkavoKit",
            dependencies: [
                "ArkavoAgent",
                "ArkavoSocial",
                "ArkavoContent",
                "ArkavoRecorder",
                "ArkavoStreaming"
            ]
        ),
        .target(
            name: "ArkavoAgent",
            dependencies: ["ArkavoSocial"]
        ),
        .target(
            name: "ArkavoSocial",
            dependencies: ["OpenTDFKit"]
        ),
        .target(
            name: "ArkavoContent",
            dependencies: []
        ),
        .target(
            name: "ArkavoRecorder",
            dependencies: ["ArkavoStreaming"]
        ),
        .target(
            name: "ArkavoStreaming",
            dependencies: []
        ),
        .testTarget(
            name: "ArkavoKitTests",
            dependencies: ["ArkavoKit"]
        ),
        .target(
            name: "ArkavoC2PA",
            dependencies: []
        ),
    ]
)