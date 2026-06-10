// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loopera",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Loopera", targets: ["LoopStage"])
    ],
    targets: [
        .executableTarget(
            name: "LoopStage",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ]
)
