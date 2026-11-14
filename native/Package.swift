// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetilyNative",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Meetily",
            path: "Sources/Meetily",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
