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
        .library(name: "SongbirdDistributed", targets: ["SongbirdDistributed"]),
        .library(name: "SongbirdPostgres", targets: ["SongbirdPostgres"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
        .package(url: "git@github.com:rgb/smew.git", exact: "0.34.4"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.29.0"),
        .package(url: "https://github.com/hummingbird-project/postgres-migrations.git", from: "1.1.0"),
        .package(url: "https://github.com/Mongey/swift-test-containers.git", branch: "main"),
    ],
    targets: [
        // MARK: - Core

        .target(
            name: "Songbird",
            dependencies: [
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Logging", package: "swift-log"),
            ]
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
                .product(name: "Logging", package: "swift-log"),
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

        // MARK: - Distributed

        .target(
            name: "SongbirdDistributed",
            dependencies: [
                "Songbird",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        // MARK: - Postgres

        .target(
            name: "SongbirdPostgres",
            dependencies: [
                "Songbird",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "PostgresMigrations", package: "postgres-migrations"),
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
            name: "SongbirdPostgresTests",
            dependencies: [
                "SongbirdPostgres",
                "SongbirdTesting",
                .product(name: "TestContainers", package: "swift-test-containers"),
            ]
        ),

        .testTarget(
            name: "SongbirdSmewTests",
            dependencies: ["SongbirdSmew", "SongbirdTesting"]
        ),

        .testTarget(
            name: "SongbirdDistributedTests",
            dependencies: ["SongbirdDistributed", "SongbirdTesting"]
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
