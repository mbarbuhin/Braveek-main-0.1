// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoMeetingRecorder",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AutoMeetingRecorder",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
