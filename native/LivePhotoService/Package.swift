// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let helperInfoPlist = packageDirectory
    .appendingPathComponent("Sources/LivePhotoService/Helper-Info.plist")
    .path

let package = Package(
    name: "LivePhotoService",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "live-photo-service", targets: ["LivePhotoService"])],
    dependencies: [
        .package(path: "../LivesCore"),
    ],
    targets: [
        .executableTarget(
            name: "LivePhotoService",
            dependencies: ["LivesCore"],
            exclude: ["Helper-Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", helperInfoPlist,
                ])
            ]
        ),
        .testTarget(name: "LivePhotoServiceTests", dependencies: ["LivePhotoService"])
    ]
)
