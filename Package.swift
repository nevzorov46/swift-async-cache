// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-async-cache",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "AsyncCache", targets: ["AsyncCache"])
    ],
    targets: [
        .target(name: "AsyncCache", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AsyncCacheTests", dependencies: ["AsyncCache"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
