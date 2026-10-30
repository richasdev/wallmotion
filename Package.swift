// swift-tools-version: 6.0
import PackageDescription
import Foundation

let nativeLibraryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/native/release").path

let package = Package(
    name: "Wallmotion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WallmotionCore", targets: ["WallmotionCore"]),
        .executable(name: "Wallmotion", targets: ["Wallmotion"])
    ],
    targets: [
        .target(name: "CWallmotionMedia", linkerSettings: [
            .unsafeFlags(["-L", nativeLibraryPath]),
            .linkedLibrary("wallmotion_media"),
            .linkedLibrary("iconv")
        ]),
        .target(name: "WallmotionCore", dependencies: ["CWallmotionMedia"]),
        .executableTarget(name: "Wallmotion", dependencies: ["WallmotionCore"]),
        .testTarget(name: "WallmotionCoreTests", dependencies: ["WallmotionCore"]),
        .testTarget(name: "WallmotionAppTests", dependencies: ["Wallmotion"])
    ]
)
