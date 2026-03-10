// swift-tools-version: 6.2
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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.3")
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
