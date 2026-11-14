// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetilyNative",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "Meetily",
            dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")],
            path: "Sources/Meetily",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
