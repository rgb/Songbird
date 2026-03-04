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
        .library(name: "SongbirdSmew", targets: ["SongbirdSmew"]),
        .library(name: "SongbirdHummingbird", targets: ["SongbirdHummingbird"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
        .package(url: "git@github.com:rgb/smew.git", exact: "0.34.4"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
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

        // MARK: - Smew (DuckDB)

        .target(
            name: "SongbirdSmew",
            dependencies: [
                "Songbird",
                .product(name: "Smew", package: "smew"),
            ]
        ),

        // MARK: - Hummingbird Integration

        .target(
            name: "SongbirdHummingbird",
            dependencies: [
                "Songbird",
                .product(name: "Hummingbird", package: "hummingbird"),
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

        .testTarget(
            name: "SongbirdSmewTests",
            dependencies: ["SongbirdSmew", "SongbirdTesting"]
        ),

        .testTarget(
            name: "SongbirdHummingbirdTests",
            dependencies: [
                "SongbirdHummingbird",
                "SongbirdTesting",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
