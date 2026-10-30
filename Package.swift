// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallmotion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WallmotionCore", targets: ["WallmotionCore"]),
        .executable(name: "Wallmotion", targets: ["Wallmotion"])
    ],
    targets: [
        .target(name: "WallmotionCore"),
        .executableTarget(name: "Wallmotion", dependencies: ["WallmotionCore"]),
        .testTarget(name: "WallmotionCoreTests", dependencies: ["WallmotionCore"]),
        .testTarget(name: "WallmotionAppTests", dependencies: ["Wallmotion"])
    ]
)
