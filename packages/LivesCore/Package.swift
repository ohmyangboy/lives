// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LivesCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "LivesCore", targets: ["LivesCore"]),
    ],
    targets: [
        .target(
            name: "LivesCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LivesCoreTests", dependencies: ["LivesCore"]),
    ]
)
