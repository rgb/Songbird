// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Songbird",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Songbird", targets: ["Songbird"]),
        .library(name: "SongbirdTesting", targets: ["SongbirdTesting"]),
        .library(name: "SongbirdSQLite", targets: ["SongbirdSQLite"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
    ],
    targets: [
        // MARK: - Core

        .target(
            name: "Songbird"
        ),

        // MARK: - Testing

        .target(
            name: "SongbirdTesting",
            dependencies: ["Songbird"]
        ),

        // MARK: - SQLite

        .target(
            name: "SongbirdSQLite",
            dependencies: [
                "Songbird",
                .product(name: "SQLite", package: "SQLite.swift"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "SongbirdTests",
            dependencies: ["Songbird", "SongbirdTesting"]
        ),

        .testTarget(
            name: "SongbirdTestingTests",
            dependencies: ["SongbirdTesting"]
        ),

        .testTarget(
            name: "SongbirdSQLiteTests",
            dependencies: ["SongbirdSQLite", "SongbirdTesting"]
        ),
    ]
)
