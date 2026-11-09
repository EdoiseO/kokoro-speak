// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KokoroSpeak",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "KokoroSpeak", path: "Sources/KokoroSpeak")
    ]
)
