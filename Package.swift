// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wordy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Wordy", path: "Sources/Wordy"),
        .testTarget(name: "WordyTests", dependencies: ["Wordy"], path: "Tests/WordyTests")
    ]
)
