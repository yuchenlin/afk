// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AFK",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AFK", targets: ["AFK"]),
        .library(name: "AFKCore", targets: ["AFKCore"]),
    ],
    targets: [
        .target(
            name: "AFKCore",
            path: "Sources/AFKCore"
        ),
        .executableTarget(
            name: "AFK",
            dependencies: ["AFKCore"],
            path: "Sources/AFKApp"
        ),
        .testTarget(
            name: "AFKCoreTests",
            dependencies: ["AFKCore"],
            path: "Tests/AFKCoreTests"
        ),
    ]
)
