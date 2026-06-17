// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GameNest",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GameNest", targets: ["GameNest"])
    ],
    targets: [
        .executableTarget(
            name: "GameNest",
            path: "Sources/GameNest"
        ),
        .testTarget(
            name: "GameNestTests",
            dependencies: ["GameNest"]
        )
    ]
)
