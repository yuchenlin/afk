// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AFK",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "AFKCore", targets: ["AFKCore"]),
    ],
    targets: [
        .target(
            name: "AFKCore",
            path: "Sources/AFKCore"
        ),
        .testTarget(
            name: "AFKCoreTests",
            dependencies: ["AFKCore"],
            path: "Tests/AFKCoreTests"
        ),
    ]
)
