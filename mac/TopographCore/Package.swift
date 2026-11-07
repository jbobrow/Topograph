// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopographCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TopographCore", targets: ["TopographCore"]),
        .executable(name: "topograph-native", targets: ["topograph-native"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        // macOS reads WebP but can't write it, and the library's copies are WebP. libwebp, as is.
        .target(name: "CWebP", cSettings: [.headerSearchPath("."), .unsafeFlags(["-O2", "-w"])]),
        .target(name: "TopographCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "CWebP"],
                resources: [.copy("Resources/clip-merges.txt"), .copy("Resources/html-entities.txt"), .copy("Resources/concepts.txt")],
                // Optimized even in a Debug build: the map's math runs many times a second
                // as the timeline plays, and takes about 15 times as long without this.
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // The pipeline from the command line, for trying it on a throwaway library.
        .executableTarget(name: "topograph-native", dependencies: ["TopographCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "TopographCoreTests", dependencies: ["TopographCore"]),
    ]
)
