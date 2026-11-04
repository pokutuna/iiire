// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Koe",
            path: "Sources/Koe",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
