//
//  GMRoutesService.swift
//  MapsIndoorsGoogleMaps
//
//  Created by Aditya Singh Gaharwar on 05/06/2026.
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation
import MapsIndoors
import MapsIndoorsCore

enum GMRoutesServiceError: Error {
    /// HTTP 403 whose cause is that the key cannot call the Routes API — either
    /// the Routes API is not enabled for the key's project (`SERVICE_DISABLED`)
    /// or it is enabled for the project but not for this key
    /// (`API_KEY_SERVICE_DISABLED`). Callers fall back to the legacy
    /// Directions/Distance Matrix APIs on exactly these errors.
    case notAuthorized
    /// Any other non-success HTTP status (including 403s with other causes).
    case requestFailed(statusCode: Int)
}

/// The Routes API error envelope (`{ "error": { "status", "details": [...] } }`),
/// decoded only far enough to read the failure reason behind a 403.
private struct GMRoutesErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let reason: String?
        }

        let status: String?
        let message: String?
        let details: [Detail]?
    }

    let error: ErrorBody?
}

/// Client for the Google Routes API (the replacement for the legacy
/// Directions and Distance Matrix APIs, which Google retired for new
/// projects in March 2025). Responses are mapped into the legacy model
/// types so `asMPRoute` / `asMPMatrix` remain the single converters to
/// MapsIndoors routing types.
class GMRoutesService {
    private static let computeRoutesURL = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!
    private static let computeRouteMatrixURL = URL(string: "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix")!

    /// Only fields the legacy converters actually consume — the field mask is
    /// mandatory on the Routes API and bounds response size/billing.
    private static let routesFieldMask = [
        "routes.description",
        "routes.warnings",
        "routes.legs.distanceMeters",
        "routes.legs.duration",
        "routes.legs.startLocation",
        "routes.legs.endLocation",
        "routes.legs.steps.distanceMeters",
        "routes.legs.steps.staticDuration",
        "routes.legs.steps.startLocation",
        "routes.legs.steps.endLocation",
        "routes.legs.steps.navigationInstruction",
        "routes.legs.steps.polyline",
        "routes.legs.steps.travelMode",
        "routes.legs.steps.transitDetails",
    ].joined(separator: ",")

    private static let matrixFieldMask = "originIndex,destinationIndex,condition,distanceMeters,duration"

    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func computeRoute(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, config: MPDirectionsConfig) async throws -> GoogleRouteResponse {
        let travelMode = Self.travelMode(for: config)
        var request = GMComputeRoutesRequest(
            origin: GMRoutesWaypoint(coordinate: origin.latitude, origin.longitude),
            destination: GMRoutesWaypoint(coordinate: destination.latitude, destination.longitude),
            travelMode: travelMode)
        // The legacy service defaulted to "en" when the config has no
        // language; keep parity (otherwise Google answers in the locale of
        // the route's region).
        request.languageCode = config.language ?? "en"
        request.units = "METRIC"
        request.routeModifiers = Self.routeModifiers(for: config)

        // The Routes API rejects time fields for WALK/BICYCLE, and arrivalTime
        // is transit-only. Omitted fields default to "now".
        if travelMode == "TRANSIT", let arrival = config.arrival {
            request.arrivalTime = Self.rfc3339(arrival)
        } else if travelMode == "DRIVE" || travelMode == "TRANSIT" {
            request.departureTime = Self.futureDeparture(config.departure)
        }

        if travelMode == "DRIVE" {
            request.routingPreference = "TRAFFIC_AWARE"
        }
        if travelMode == "TRANSIT" {
            // Matches the legacy `transit_routing_preference=less_walking`.
            // Unlike the legacy service we do not restrict the vehicle types
            // (it hardcoded `transit_mode=bus`) — all transit modes are allowed.
            request.transitPreferences = GMRoutesTransitPreferences(routingPreference: "LESS_WALKING")
        }

        let data = try await post(to: Self.computeRoutesURL, body: request, fieldMask: Self.routesFieldMask)
        return try JSONDecoder().decode(GMComputeRoutesResponse.self, from: data).asLegacyRouteResponse
    }

    func computeRouteMatrix(origins: [CLLocationCoordinate2D], destinations: [CLLocationCoordinate2D], config: MPDirectionsConfig) async throws -> GoogleDistanceMatrix {
        // computeRouteMatrix rejects TRANSIT (400) — unlike computeRoutes it only
        // accepts DRIVE/WALK/BICYCLE/TWO_WHEELER. The legacy matrix ignored travel
        // mode entirely (it defaulted to driving), so coerce transit to driving
        // here to preserve that behavior rather than hard-failing the request.
        let travelMode = Self.matrixTravelMode(for: config)
        // The matrix attaches route modifiers to each origin (not the request),
        // so compute them once and apply to every origin waypoint.
        let modifiers = Self.routeModifiers(for: config)
        var request = GMComputeRouteMatrixRequest(
            origins: origins.map { GMComputeRouteMatrixRequest.MatrixOrigin(waypoint: GMRoutesWaypoint(coordinate: $0.latitude, $0.longitude), routeModifiers: modifiers) },
            destinations: destinations.map { GMComputeRouteMatrixRequest.MatrixDestination(waypoint: GMRoutesWaypoint(coordinate: $0.latitude, $0.longitude)) },
            travelMode: travelMode)
        request.languageCode = config.language ?? "en"
        request.units = "METRIC"

        // travelMode is never TRANSIT here (coerced above), so arrivalTime — which
        // is transit-only — does not apply; only driving carries a departure time.
        if travelMode == "DRIVE" {
            request.departureTime = Self.futureDeparture(config.departure)
            request.routingPreference = "TRAFFIC_AWARE"
        }

        let data = try await post(to: Self.computeRouteMatrixURL, body: request, fieldMask: Self.matrixFieldMask)
        let elements = try JSONDecoder().decode([GMRouteMatrixElement].self, from: data)
        return elements.asLegacyDistanceMatrix(originCount: origins.count, destinationCount: destinations.count)
    }

    // MARK: - Request plumbing

    private func post(to url: URL, body: some Encodable, fieldMask: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode != 200 {
            if statusCode == 403, Self.isRoutesServiceDisabled(body: data) {
                throw GMRoutesServiceError.notAuthorized
            }
            MPLog.google.error("Routes API request failed (\(statusCode)): \(String(data: data, encoding: .utf8) ?? "<no body>")")
            throw GMRoutesServiceError.requestFailed(statusCode: statusCode)
        }

        return data
    }

    /// The legacy fallback fires only when a 403 means this key permanently
    /// cannot call the Routes API. Two error reasons qualify:
    /// - `SERVICE_DISABLED` — the Routes API is not enabled for the key's project.
    /// - `API_KEY_SERVICE_DISABLED` — the Routes API is enabled for the project
    ///   but not for this key.
    /// Both are the permanent "this key cannot use Routes" condition SPEX-1905
    /// targets. Every other 403 (quota/rate limits, key or referer restrictions)
    /// is transient or account-specific and is surfaced as an error, rather than
    /// silently pinning the key to the legacy API for the rest of the process
    /// lifetime.
    private static let routesUnavailableReasons: Set<String> = ["SERVICE_DISABLED", "API_KEY_SERVICE_DISABLED"]

    private static func isRoutesServiceDisabled(body: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(GMRoutesErrorEnvelope.self, from: body) else { return false }
        return envelope.error?.details?.contains { detail in
            guard let reason = detail.reason else { return false }
            return routesUnavailableReasons.contains(reason)
        } ?? false
    }

    private static func travelMode(for config: MPDirectionsConfig) -> String {
        switch config.travelMode {
        case .driving: "DRIVE"
        case .walking: "WALK"
        case .bicycling: "BICYCLE"
        case .transit: "TRANSIT"
        default: "DRIVE"
        }
    }

    /// The Routes API computeRouteMatrix endpoint accepts only
    /// DRIVE/WALK/BICYCLE/TWO_WHEELER — a TRANSIT matrix request returns 400. The
    /// legacy matrix ignored travel mode (it defaulted to driving), so transit is
    /// coerced to driving to keep matrix requests working instead of failing.
    static func matrixTravelMode(for config: MPDirectionsConfig) -> String {
        let mode = travelMode(for: config)
        return mode == "TRANSIT" ? "DRIVE" : mode
    }

    private static func routeModifiers(for config: MPDirectionsConfig) -> GMRoutesRouteModifiers? {
        var modifiers = GMRoutesRouteModifiers()
        var hasModifier = false
        // The Routes API only accepts `avoidIndoor` for WALK and 400s for other modes
        // (legacy Directions tolerated it everywhere), so it is gated to WALK here. The
        // other avoid types are valid on every mode.
        let mode = travelMode(for: config)
        for avoid in config.avoidTypes ?? [] {
            switch avoid.typeString {
            case "ferries": modifiers.avoidFerries = true
            case "highways": modifiers.avoidHighways = true
            case "tolls": modifiers.avoidTolls = true
            case "indoor" where mode == "WALK": modifiers.avoidIndoor = true
            default: continue
            }
            hasModifier = true
        }
        return hasModifier ? modifiers : nil
    }

    private static func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// The Routes API rejects a non-transit `departureTime` that is not in the
    /// future, and `MPDirectionsConfig.departure` defaults to "now" — which is
    /// already in the past by the time the request reaches Google. Forward only
    /// a genuinely-future departure; otherwise return nil so the Routes API
    /// defaults `departureTime` to the request time.
    static func futureDeparture(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        return rfc3339(date)
    }
}
