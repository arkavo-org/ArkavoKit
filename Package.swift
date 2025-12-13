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
        .library(
            name: "ArkavoStore",
            targets: ["ArkavoStore"]
        ),
        .executable(
            name: "ntdf-test",
            targets: ["NTDFTestCLI"]
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
                "ArkavoMedia",
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
            name: "ArkavoMedia",
            dependencies: []
        ),
        .target(
            name: "ArkavoRecorder",
            dependencies: ["ArkavoMedia", "ArkavoStreaming"]
        ),
        .target(
            name: "ArkavoStreaming",
            dependencies: ["ArkavoMedia", "OpenTDFKit"]
        ),
        .testTarget(
            name: "ArkavoKitTests",
            dependencies: ["ArkavoKit", "ArkavoRecorder", "ArkavoStreaming", "ArkavoMedia"]
        ),
        .target(
            name: "ArkavoC2PA",
            dependencies: []
        ),
        .target(
            name: "ArkavoStore",
            dependencies: [],
            exclude: ["StoreKitConfiguration.storekit"]
        ),
        .executableTarget(
            name: "NTDFTestCLI",
            dependencies: ["ArkavoStreaming", "ArkavoMedia", "OpenTDFKit"]
        ),
    ]
)
