// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Lit",
    products: [
        .library(
            name: "Lit",
            targets: ["Lit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "Lit",
            dependencies: ["NIO", "NIOHTTP1"]
        ),
        .testTarget(
            name: "LitTests",
            dependencies: ["Lit", "NIOConcurrencyHelpers"]
        ),
    ]
)
