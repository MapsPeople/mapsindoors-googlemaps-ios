// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let mapsindoorsVersion = Version("4.6.1")

let package = Package(
    name: "MapsIndoorsGoogleMaps",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "MapsIndoorsGoogleMaps",
            targets: ["MapsIndoorsGoogleMaps"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MapsPeople/mapsindoors-core-ios.git", exact: mapsindoorsVersion),
        .package(url: "https://github.com/googlemaps/ios-maps-sdk.git", exact: "8.4.0"),
    ],
    targets: [
        .target(
            name: "MapsIndoorsGoogleMaps",
            dependencies: [
                .product(name: "MapsIndoorsCore", package: "mapsindoors-core-ios"),
                .product(name: "GoogleMaps", package: "ios-maps-sdk"),
                .product(name: "GoogleMapsBase", package: "ios-maps-sdk"),
                .product(name: "GoogleMapsCore", package: "ios-maps-sdk"),
            ]
        ),
    ]
)
