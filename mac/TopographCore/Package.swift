// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopographCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TopographCore", targets: ["TopographCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        .target(name: "TopographCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                resources: [.copy("Resources/clip-merges.txt"), .copy("Resources/html-entities.txt")],
                // Optimized even in a Debug build: the map's math runs many times a second
                // as the timeline plays, and takes about 15 times as long without this.
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "TopographCoreTests", dependencies: ["TopographCore"]),
    ]
)
