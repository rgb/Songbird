// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerPG",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(name: "Songbird", path: "../../"),
        .package(name: "Warbler", path: "../warbler"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Warbler",
            dependencies: [
                .product(name: "WarblerIdentity", package: "Warbler"),
                .product(name: "WarblerCatalog", package: "Warbler"),
                .product(name: "WarblerSubscriptions", package: "Warbler"),
                .product(name: "WarblerAnalytics", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdPostgres", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
    ]
)
