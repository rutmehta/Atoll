// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentNook",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentNook",
            path: "Sources/AgentNook",
            resources: [
                .copy("Resources/Adapters")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
