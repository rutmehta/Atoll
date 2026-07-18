// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentNook",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ejbills/mediaremote-adapter.git", branch: "master")
    ],
    targets: [
        .executableTarget(
            name: "AgentNook",
            dependencies: [
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter")
            ],
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
