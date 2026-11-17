// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DiskLens", targets: ["DiskLens"]),
        .library(name: "DiskLensCore", targets: ["DiskLensCore"]),
    ],
    targets: [
        .target(name: "DiskLensCore"),
        .executableTarget(name: "DiskLens", dependencies: ["DiskLensCore"]),
        .testTarget(name: "DiskLensCoreTests", dependencies: ["DiskLensCore"]),
    ]
)
