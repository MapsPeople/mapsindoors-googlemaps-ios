// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let mapsindoorsVersion = Version("4.12.2")

let package = Package(
    name: "MapsIndoorsGoogleMaps",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "MapsIndoorsGoogleMaps",
            targets: ["MapsIndoorsGoogleMaps"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MapsPeople/mapsindoors-core-ios.git", exact: mapsindoorsVersion),
        .package(url: "https://github.com/googlemaps/ios-maps-sdk.git", exact: "9.4.0"),
    ],
    targets: [
        .target(
            name: "MapsIndoorsGoogleMaps",
            dependencies: [
                .product(name: "MapsIndoorsCore", package: "mapsindoors-core-ios"),
                .product(name: "GoogleMaps", package: "ios-maps-sdk"),
            ]
        ),
    ]
)
