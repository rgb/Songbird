// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Warbler",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WarblerIdentity", targets: ["WarblerIdentity"]),
        .library(name: "WarblerCatalog", targets: ["WarblerCatalog"]),
        .library(name: "WarblerSubscriptions", targets: ["WarblerSubscriptions"]),
        .library(name: "WarblerAnalytics", targets: ["WarblerAnalytics"]),
    ],
    dependencies: [
        .package(name: "Songbird", path: "../../"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // MARK: - Domain Modules

        .target(
            name: "WarblerIdentity",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .target(
            name: "WarblerCatalog",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .target(
            name: "WarblerSubscriptions",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .target(
            name: "WarblerAnalytics",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        // MARK: - Executable

        .executableTarget(
            name: "Warbler",
            dependencies: [
                "WarblerIdentity",
                "WarblerCatalog",
                "WarblerSubscriptions",
                "WarblerAnalytics",
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "WarblerIdentityTests",
            dependencies: [
                "WarblerIdentity",
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .testTarget(
            name: "WarblerCatalogTests",
            dependencies: [
                "WarblerCatalog",
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .testTarget(
            name: "WarblerSubscriptionsTests",
            dependencies: [
                "WarblerSubscriptions",
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),

        .testTarget(
            name: "WarblerAnalyticsTests",
            dependencies: [
                "WarblerAnalytics",
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
            ]
        ),
    ]
)
