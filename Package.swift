// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Songbird",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Songbird", targets: ["Songbird"]),
    ],
    targets: [
        // MARK: - Core

        .target(
            name: "Songbird"
        ),

        // MARK: - Tests

        .testTarget(
            name: "SongbirdTests",
            dependencies: ["Songbird"]
        ),
    ]
)
