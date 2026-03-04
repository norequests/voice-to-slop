// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TelegramVoiceHotkey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TelegramVoiceHotkey",
            path: "Sources",
            exclude: ["CTDLib"]
        ),
    ]
)
