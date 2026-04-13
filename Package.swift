// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "CodeIslandCore",
            path: "Sources/CodeIslandCore"
        ),
        .executableTarget(
            name: "CodeIsland",
            dependencies: [
                "CodeIslandCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/CodeIsland",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "codeisland-bridge",
            dependencies: ["CodeIslandCore"],
            path: "Sources/CodeIslandBridge"
        ),
        .testTarget(
            name: "CodeIslandCoreTests",
            dependencies: ["CodeIslandCore"],
            path: "Tests/CodeIslandCoreTests"
        ),
        .testTarget(
            name: "CodeIslandTests",
            dependencies: ["CodeIsland"],
            path: "Tests/CodeIslandTests"
        ),
    ]
)
