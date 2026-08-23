// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrimsonRail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CrimsonRail", targets: ["CrimsonRail"])
    ],
    targets: [
        .executableTarget(
            name: "CrimsonRail",
            path: "Sources/CrimsonRail",
            swiftSettings: [
                // The game loop is single-threaded around SceneKit's render callback;
                // Swift 6 strict concurrency buys nothing here and fights every delegate.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
