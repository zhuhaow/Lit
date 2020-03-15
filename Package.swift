// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "nekit2",
    products: [
        .library(
            name: "nekit2",
            targets: ["nekit2"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "nekit2",
            dependencies: []
        ),
        .testTarget(
            name: "nekit2Tests",
            dependencies: ["nekit2"]
        )
    ]
)
