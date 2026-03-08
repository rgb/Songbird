// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerDistributed",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(name: "Songbird", path: "../../"),
        .package(name: "Warbler", path: "../warbler"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // MARK: - Gateway (HTTP → distributed actor calls)

        .executableTarget(
            name: "WarblerGateway",
            dependencies: [
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Workers (domain-specific processes)

        .executableTarget(
            name: "WarblerIdentityWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerIdentity", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerCatalogWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerCatalog", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerSubscriptionsWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerSubscriptions", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerAnalyticsWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerAnalytics", package: "Warbler"),
            ]
        ),
    ]
)
