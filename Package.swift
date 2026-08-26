// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-rec",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "mac-rec",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/mac-rec",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
