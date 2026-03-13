// swift-tools-version:6.2
import PackageDescription

// Shared Swift settings for all targets - enables unused code warnings
let sharedSwiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=200",
        "-Xfrontend", "-warn-long-expression-type-checking=100"
    ], .when(configuration: .debug))
]

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
        .executable(
            name: "tdf-create",
            targets: ["TDFCreateCLI"]
        ),
        .executable(
            name: "tdf-fetch",
            targets: ["TDFFetchCLI"]
        ),
        .executable(
            name: "c2pa-test",
            targets: ["C2PATestCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/arkavo-org/OpenTDFKit", revision: "d8ffeff"),
        .package(url: "https://github.com/arkavo-org/iroh-swift", from: "0.2.5"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
        .package(path: "../ArkavoMediaKit")
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
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArkavoAgent",
            dependencies: ["ArkavoSocial"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArkavoSocial",
            dependencies: [
                "OpenTDFKit",
                .product(name: "IrohSwift", package: "iroh-swift"),
                "ZIPFoundation",
                .product(name: "ArkavoMediaKit", package: "ArkavoMediaKit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArkavoContent",
            dependencies: [],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArkavoMedia",
            dependencies: [],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArkavoRecorder",
            dependencies: ["ArkavoMedia", "ArkavoStreaming"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArkavoStreaming",
            dependencies: ["ArkavoMedia", "OpenTDFKit"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "ArkavoKitTests",
            dependencies: [
                "ArkavoKit",
                "ArkavoRecorder",
                "ArkavoStreaming",
                "ArkavoMedia",
                "ArkavoSocial",
                .product(name: "ArkavoMediaKit", package: "ArkavoMediaKit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArkavoC2PA",
            dependencies: [],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArkavoStore",
            dependencies: [],
            exclude: ["StoreKitConfiguration.storekit"],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "NTDFTestCLI",
            dependencies: ["ArkavoStreaming", "ArkavoMedia", "OpenTDFKit"],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "TDFCreateCLI",
            dependencies: [
                "ArkavoSocial",
                .product(name: "IrohSwift", package: "iroh-swift"),
                .product(name: "ArkavoMediaKit", package: "ArkavoMediaKit"),
                "OpenTDFKit",
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "TDFFetchCLI",
            dependencies: [
                "ArkavoSocial",
                .product(name: "IrohSwift", package: "iroh-swift"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "C2PATestCLI",
            dependencies: ["ArkavoC2PA"],
            swiftSettings: sharedSwiftSettings,
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)
