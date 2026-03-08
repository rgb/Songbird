// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerP2P",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(name: "Songbird", path: "../../"),
        .package(name: "Warbler", path: "../warbler"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // MARK: - Identity Service (:8081)

        .executableTarget(
            name: "WarblerIdentityService",
            dependencies: [
                .product(name: "WarblerIdentity", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Catalog Service (:8082)

        .executableTarget(
            name: "WarblerCatalogService",
            dependencies: [
                .product(name: "WarblerCatalog", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Subscriptions Service (:8083)

        .executableTarget(
            name: "WarblerSubscriptionsService",
            dependencies: [
                .product(name: "WarblerSubscriptions", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Analytics Service (:8084)

        .executableTarget(
            name: "WarblerAnalyticsService",
            dependencies: [
                .product(name: "WarblerAnalytics", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
    ]
)
