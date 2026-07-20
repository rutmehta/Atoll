// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atoll",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ejbills/mediaremote-adapter.git", branch: "master"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Atoll",
            dependencies: [
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Atoll",
            exclude: [
                "Features/Agents/INTEGRATION.md",
                "Features/AgentsUI/INTEGRATION.md",
                "Features/CalendarWidget/INTEGRATION.md",
                "Features/HUD/INTEGRATION.md",
                "Features/Media/INTEGRATION.md",
                "Features/Mirror/INTEGRATION.md",
                "Features/Notes/INTEGRATION.md",
                "Features/Shelf/INTEGRATION.md",
                "Features/ShortcutsRunner/INTEGRATION.md",
                "Features/SystemEvents/INTEGRATION.md",
                "Features/Timers/INTEGRATION.md",
                "Features/Todos/INTEGRATION.md"
            ],
            resources: [
                .copy("Resources/Adapters")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
