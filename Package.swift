// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoMeetingRecorder",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/supabase-community/supabase-swift", .upToNextMajor(from: "2.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "AutoMeetingRecorder",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
