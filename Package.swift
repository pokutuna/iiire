// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Koe",
            path: "Sources/Koe"
        ),
        .testTarget(name: "KoeTests", dependencies: ["Koe"], path: "Tests/KoeTests"),
    ]
)
