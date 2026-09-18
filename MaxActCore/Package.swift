// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MaxActCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MaxActCore", targets: ["MaxActCore"])
    ],
    targets: [
        .target(
            name: "MaxActCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MaxActCoreTests",
            dependencies: ["MaxActCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
