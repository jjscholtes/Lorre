// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Lorre",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Lorre", targets: ["Lorre"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.5")
    ],
    targets: [
        .executableTarget(
            name: "Lorre",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .testTarget(
            name: "LorreTests",
            dependencies: ["Lorre"]
        ),
    ]
)
