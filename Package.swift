// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GoogleCloudLogging",
    platforms: [.iOS(.v17)],
    products: [
        .library(
            name: "GoogleCloudLogging",
            targets: ["GoogleCloudLogging"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "GoogleCloudLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "GoogleCloudLoggingTests",
            dependencies: ["GoogleCloudLogging"]
        ),
    ]
)
