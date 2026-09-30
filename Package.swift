// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "weft",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "weft", targets: ["weft"]),
        .executable(name: "weft-demo", targets: ["weftDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system", from: "1.8.0")
    ],
    targets: [
        .target(name: "weft", dependencies: [.product(name: "SystemPackage", package: "swift-system")]),
        .executableTarget(name: "weftDemo", dependencies: ["weft"], path: "Examples/Demo"),
        .testTarget(name: "weftTests", dependencies: ["weft"]),
    ]
)
