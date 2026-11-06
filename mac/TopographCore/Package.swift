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
        .target(name: "TopographCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "TopographCoreTests", dependencies: ["TopographCore"]),
    ]
)
