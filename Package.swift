// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snowpile",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "Snowpile",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Snowpile"
        ),
        .testTarget(name: "SnowpileTests", dependencies: ["Snowpile"], path: "Tests/SnowpileTests")
    ]
)
