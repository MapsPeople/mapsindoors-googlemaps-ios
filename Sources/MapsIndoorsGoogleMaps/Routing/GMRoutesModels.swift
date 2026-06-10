//
//  GMRoutesModels.swift
//  MapsIndoorsGoogleMaps
//
//  Created by Aditya Singh Gaharwar on 05/06/2026.
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation

// MARK: - Routes API v2 request models
// https://developers.google.com/maps/documentation/routes

struct GMRoutesLatLng: Codable {
    let latitude: Double
    let longitude: Double
}

struct GMRoutesWaypoint: Encodable {
    struct Location: Encodable {
        let latLng: GMRoutesLatLng
    }

    let location: Location

    init(coordinate latitude: Double, _ longitude: Double) {
        location = Location(latLng: GMRoutesLatLng(latitude: latitude, longitude: longitude))
    }
}

struct GMRoutesRouteModifiers: Encodable {
    var avoidTolls: Bool?
    var avoidHighways: Bool?
    var avoidFerries: Bool?
    var avoidIndoor: Bool?
}

struct GMRoutesTransitPreferences: Encodable {
    var allowedTravelModes: [String]?
    var routingPreference: String?
}

struct GMComputeRoutesRequest: Encodable {
    let origin: GMRoutesWaypoint
    let destination: GMRoutesWaypoint
    let travelMode: String
    var routingPreference: String?
    var departureTime: String?
    var arrivalTime: String?
    var computeAlternativeRoutes = false
    var routeModifiers: GMRoutesRouteModifiers?
    var languageCode: String?
    var units: String?
    var transitPreferences: GMRoutesTransitPreferences?
}

struct GMComputeRouteMatrixRequest: Encodable {
    struct MatrixOrigin: Encodable {
        let waypoint: GMRoutesWaypoint
        // Unlike computeRoutes, the matrix carries route modifiers per origin
        // rather than at the request top level.
        var routeModifiers: GMRoutesRouteModifiers?
    }

    struct MatrixDestination: Encodable {
        let waypoint: GMRoutesWaypoint
    }

    let origins: [MatrixOrigin]
    let destinations: [MatrixDestination]
    let travelMode: String
    var routingPreference: String?
    var departureTime: String?
    var arrivalTime: String?
    var languageCode: String?
    var units: String?
    var transitPreferences: GMRoutesTransitPreferences?
}

// MARK: - Routes API v2 response models

struct GMRoutesLocation: Decodable {
    let latLng: GMRoutesLatLng?
}

struct GMComputeRoutesResponse: Decodable {
    let routes: [GMRoutesRoute]?
}

struct GMRoutesRoute: Decodable {
    let description: String?
    let warnings: [String]?
    let legs: [GMRoutesLeg]?
}

struct GMRoutesLeg: Decodable {
    let distanceMeters: Double?
    let duration: String?
    let startLocation: GMRoutesLocation?
    let endLocation: GMRoutesLocation?
    let steps: [GMRoutesStep]?
}

struct GMRoutesStep: Decodable {
    struct NavigationInstruction: Decodable {
        let maneuver: String?
        let instructions: String?
    }

    struct Polyline: Decodable {
        let encodedPolyline: String?
    }

    let distanceMeters: Double?
    let staticDuration: String?
    let polyline: Polyline?
    let startLocation: GMRoutesLocation?
    let endLocation: GMRoutesLocation?
    let navigationInstruction: NavigationInstruction?
    let travelMode: String?
    let transitDetails: GMRoutesTransitDetails?
}

struct GMRoutesTransitDetails: Decodable {
    struct StopDetails: Decodable {
        let arrivalStop: Stop?
        let departureStop: Stop?
        /// RFC 3339 timestamps.
        let arrivalTime: String?
        let departureTime: String?

        struct Stop: Decodable {
            let name: String?
            let location: GMRoutesLocation?
        }
    }

    struct LocalizedValues: Decodable {
        struct LocalizedTime: Decodable {
            struct LocalizedText: Decodable {
                let text: String?
            }

            let time: LocalizedText?
            let timeZone: String?
        }

        let arrivalTime: LocalizedTime?
        let departureTime: LocalizedTime?
    }

    struct TransitLine: Decodable {
        struct Agency: Decodable {
            let name: String?
            let uri: String?
        }

        struct Vehicle: Decodable {
            struct LocalizedText: Decodable {
                let text: String?
            }

            let name: LocalizedText?
            let type: String?
            let iconUri: String?
        }

        let agencies: [Agency]?
        let name: String?
        let nameShort: String?
        let vehicle: Vehicle?
    }

    let stopDetails: StopDetails?
    let localizedValues: LocalizedValues?
    let headsign: String?
    let transitLine: TransitLine?
    let stopCount: Int?
    let tripShortText: String?
}

/// One element of a `computeRouteMatrix` response (the response is a JSON array of these).
struct GMRouteMatrixElement: Decodable {
    let originIndex: Int?
    let destinationIndex: Int?
    /// `ROUTE_EXISTS` / `ROUTE_NOT_FOUND` / `ROUTE_MATRIX_ELEMENT_CONDITION_UNSPECIFIED`.
    let condition: String?
    let distanceMeters: Double?
    let duration: String?
}

// MARK: - Mapping to the legacy Directions/Distance Matrix models
//
// The legacy `asMPRoute` / `asMPMatrix` converters stay the single source of
// truth for producing `MPRoute` / `MPDistanceMatrixResult`, so the Routes API
// and legacy fallback paths cannot drift apart. Known, tolerated gaps:
// Routes v2 has no copyrights, no reverse-geocoded leg addresses, and
// instructions are plain text rather than HTML — `asMPRoute` defaults all of
// these.

/// Parses a Routes API protobuf-JSON duration ("3600s") into seconds.
func GMRoutesDurationSeconds(_ duration: String?) -> Double {
    guard let duration, duration.hasSuffix("s") else { return 0 }
    return Double(duration.dropLast()) ?? 0
}

extension GMComputeRoutesResponse {
    var asLegacyRouteResponse: GoogleRouteResponse {
        GoogleRouteResponse(routes: (routes ?? []).map(\.asLegacyRoute), status: "OK")
    }
}

extension GMRoutesRoute {
    var asLegacyRoute: GoogleRoute {
        GoogleRoute(
            bounds: nil,
            copyrights: "Google",
            legs: (legs ?? []).map(\.asLegacyLeg),
            overviewPolyline: nil,
            summary: description,
            warnings: warnings)
    }
}

extension GMRoutesLeg {
    var asLegacyLeg: GoogleLeg {
        GoogleLeg(
            distance: GoogleDistance(text: nil, value: distanceMeters ?? 0),
            duration: GoogleDistance(text: nil, value: GMRoutesDurationSeconds(duration)),
            endAddress: nil,
            endLocation: endLocation?.asLegacyCoordinate,
            startAddress: nil,
            startLocation: startLocation?.asLegacyCoordinate,
            steps: (steps ?? []).map(\.asLegacyStep))
    }
}

extension GMRoutesLocation {
    var asLegacyCoordinate: GoogleCoordinate {
        GoogleCoordinate(lat: latLng?.latitude, lng: latLng?.longitude)
    }
}

extension GMRoutesStep {
    var asLegacyStep: GoogleStep {
        GoogleStep(
            distance: GoogleDistance(text: nil, value: distanceMeters ?? 0),
            duration: GoogleDistance(text: nil, value: GMRoutesDurationSeconds(staticDuration)),
            endLocation: endLocation?.asLegacyCoordinate,
            htmlInstructions: navigationInstruction?.instructions,
            // The legacy converter force-unwraps `polyline!.points!` — always
            // provide a polyline, even when the field is absent in the response.
            polyline: GooglePolyline(points: polyline?.encodedPolyline ?? ""),
            startLocation: startLocation?.asLegacyCoordinate,
            travelMode: asLegacyTravelMode,
            maneuver: navigationInstruction?.maneuver,
            transit_details: transitDetails?.asLegacyTransitDetails)
    }

    private var asLegacyTravelMode: GoogleTravelMode? {
        switch travelMode {
        case "DRIVE", "TWO_WHEELER": .driving
        case "WALK": .walking
        case "BICYCLE": .bicycling
        case "TRANSIT": .transit
        default: nil
        }
    }
}

extension GMRoutesTransitDetails {
    /// The legacy transit details model is entirely non-optional, so every
    /// field gets an explicit fallback.
    var asLegacyTransitDetails: GoogleTransitDetails {
        GoogleTransitDetails(
            arrival_stop: GoogleLocation(
                location: stopDetails?.arrivalStop?.location?.asLegacyCoordinate ?? GoogleCoordinate(lat: nil, lng: nil),
                name: stopDetails?.arrivalStop?.name ?? ""),
            arrival_time: GoogleTime(
                text: localizedValues?.arrivalTime?.time?.text ?? "",
                time_zone: localizedValues?.arrivalTime?.timeZone ?? "",
                value: GMRoutesEpochSeconds(stopDetails?.arrivalTime)),
            departure_stop: GoogleLocation(
                location: stopDetails?.departureStop?.location?.asLegacyCoordinate ?? GoogleCoordinate(lat: nil, lng: nil),
                name: stopDetails?.departureStop?.name ?? ""),
            departure_time: GoogleTime(
                text: localizedValues?.departureTime?.time?.text ?? "",
                time_zone: localizedValues?.departureTime?.timeZone ?? "",
                value: GMRoutesEpochSeconds(stopDetails?.departureTime)),
            headsign: headsign ?? "",
            line: GoogleTransitLine(
                agencies: (transitLine?.agencies ?? []).map { GoogleTransitAgency(name: $0.name ?? "", url: $0.uri ?? "") },
                short_name: transitLine?.nameShort ?? transitLine?.name ?? "",
                vehicle: GoogleTransitVehicle(
                    icon: transitLine?.vehicle?.iconUri ?? "",
                    name: transitLine?.vehicle?.name?.text ?? "",
                    type: transitLine?.vehicle?.type ?? "")),
            num_stops: stopCount ?? 0,
            trip_short_name: tripShortText ?? "")
    }
}

// ISO8601DateFormatter is expensive to allocate and is parse-only here (no
// per-call mutation), so the two variants are created once and shared.
private let GMRoutesISO8601Formatter = ISO8601DateFormatter()
private let GMRoutesISO8601FractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    // Some responses carry fractional seconds, which the default options reject.
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// Parses an RFC 3339 timestamp into epoch seconds (the legacy transit time format).
func GMRoutesEpochSeconds(_ rfc3339: String?) -> Int {
    guard let rfc3339 else { return 0 }
    if let date = GMRoutesISO8601Formatter.date(from: rfc3339) {
        return Int(date.timeIntervalSince1970)
    }
    return Int(GMRoutesISO8601FractionalFormatter.date(from: rfc3339)?.timeIntervalSince1970 ?? 0)
}

extension [GMRouteMatrixElement] {
    /// Reassembles the flat element array into the legacy row/column matrix.
    /// `condition == "ROUTE_EXISTS"` maps to the legacy "OK" status; anything
    /// else (including missing indices) becomes "ZERO_RESULTS".
    func asLegacyDistanceMatrix(originCount: Int, destinationCount: Int) -> GoogleDistanceMatrix {
        var grid = [[GoogleMatrixElement]](
            repeating: [GoogleMatrixElement](
                repeating: GoogleMatrixElement(distance: nil, duration: nil, status: "ZERO_RESULTS"),
                count: destinationCount),
            count: originCount)

        for element in self {
            guard let row = element.originIndex, let column = element.destinationIndex,
                  grid.indices.contains(row), grid[row].indices.contains(column) else { continue }
            grid[row][column] = GoogleMatrixElement(
                distance: GoogleMatrixDistance(text: nil, value: element.distanceMeters ?? 0),
                duration: GoogleMatrixDistance(text: nil, value: GMRoutesDurationSeconds(element.duration)),
                status: element.condition == "ROUTE_EXISTS" ? "OK" : "ZERO_RESULTS")
        }

        return GoogleDistanceMatrix(
            destinationAddresses: nil,
            originAddresses: nil,
            rows: grid.map { GoogleMatrixRow(elements: $0) },
            status: "OK")
    }
}
