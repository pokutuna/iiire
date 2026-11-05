// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iiire",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iiire",
            path: "Sources/iiire"
        ),
        .testTarget(name: "iiireTests", dependencies: ["iiire"], path: "Tests/iiireTests"),
    ]
)
