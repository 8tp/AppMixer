// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppMixer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AppMixer",
            path: "Sources/AppMixer",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
