import Foundation
import MapsIndoorsCore

enum GoogleTravelModes {
    case driving
    case walking
    case bicycling
    case transit
}

enum GoogleAvoids {
    case tolls
    case highways
    case ferries
    case indoor
}

class GMDirectionsService: MPExternalDirectionsService {
    private let apiKey: String

    let baseUrl = "https://maps.googleapis.com/maps/api/directions/json?"

    var language = "en"

    var travelMode: GoogleTravelModes = .driving
    var avoids = [GoogleAvoids]()

    required init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Queries the Routes API first; the legacy Directions API is only used
    /// when the key cannot call the Routes API (403) — new Google projects
    /// cannot enable the legacy APIs at all (SPEX-1905).
    func query(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, config: MPDirectionsConfig) async throws -> MPRoute? {
        if GMGoogleRoutingCapability.state(for: apiKey) != .legacyOnly {
            do {
                let response = try await GMRoutesService(apiKey: apiKey).computeRoute(origin: origin, destination: destination, config: config)
                GMGoogleRoutingCapability.set(.routesAvailable, for: apiKey)
                return response.routes.first?.asMPRoute
            } catch GMRoutesServiceError.notAuthorized {
                MPLog.google.info("Routes API not authorized for this key — falling back to the legacy Directions API.")
                GMGoogleRoutingCapability.set(.legacyOnly, for: apiKey)
            }
        }
        return try await legacyQuery(origin: origin, destination: destination, config: config)
    }

    private func legacyQuery(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, config: MPDirectionsConfig) async throws -> MPRoute? {
        let url = buildUrl(origin: origin, destination: destination, config: config)
        let (data, _) = try await URLSession.shared.data(from: url)
        let deserializedResponse = try JSONDecoder().decode(GoogleRouteResponse.self, from: data)

        guard let mpRoute = deserializedResponse.routes.first?.asMPRoute else {
            return nil
        }

        return mpRoute
    }

    /// The legacy Directions request URL. Internal for tests.
    func buildUrl(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, config: MPDirectionsConfig) -> URL {
        applyConfig(config: config)

        var components = URLComponents(string: baseUrl)!
        var queryItems = [URLQueryItem]()
        queryItems.append(URLQueryItem(name: "origin", value: String(origin.latitude) + "," + String(origin.longitude)))
        queryItems.append(URLQueryItem(name: "destination", value: String(destination.latitude) + "," + String(destination.longitude)))

        queryItems.append(URLQueryItem(name: "language", value: config.language ?? language))

        queryItems.append(URLQueryItem(name: "units", value: "metric"))

        if let arrivalTime = config.arrival {
            queryItems.append(URLQueryItem(name: "arrival_time", value: String(Int(arrivalTime.timeIntervalSince1970) + 10)))
        } else if let departureTime = config.departure {
            queryItems.append(URLQueryItem(name: "departure_time", value: String(Int(departureTime.timeIntervalSince1970.rounded()) + 10)))
        } else {
            queryItems.append(URLQueryItem(name: "departure_time", value: "now"))
        }

        switch travelMode {
        case .driving:
            queryItems.append(URLQueryItem(name: "mode", value: "driving"))
        case .walking:
            queryItems.append(URLQueryItem(name: "mode", value: "walking"))
        case .bicycling:
            queryItems.append(URLQueryItem(name: "mode", value: "bicycling"))
        case .transit:
            queryItems.append(URLQueryItem(name: "mode", value: "transit"))
            queryItems.append(URLQueryItem(name: "transit_mode", value: "bus"))
        }

        if avoids.isEmpty == false {
            var avoidsString = ""
            for avoid in avoids {
                switch avoid {
                case .ferries:
                    avoidsString.append("ferries|")
                case .highways:
                    avoidsString.append("highways|")
                case .tolls:
                    avoidsString.append("tolls|")
                case .indoor:
                    avoidsString.append("indoor|")
                }
                avoidsString.removeLast()
                queryItems.append(URLQueryItem(name: "avoid", value: avoidsString))
            }
        }

        queryItems.append(URLQueryItem(name: "traffic_model", value: "best_guess"))
        queryItems.append(URLQueryItem(name: "transit_routing_preference", value: "less_walking"))

        queryItems.append(URLQueryItem(name: "key", value: apiKey))

        components.queryItems = queryItems

        return components.url!
    }

    private func applyConfig(config: MPDirectionsConfig) {
        switch config.travelMode {
        case .driving:
            travelMode = .driving
        case .walking:
            travelMode = .walking
        case .bicycling:
            travelMode = .bicycling
        case .transit:
            travelMode = .transit
        default:
            travelMode = .driving
        }

        avoids.removeAll()
        for configAvoid in config.avoidTypes ?? [] {
            switch configAvoid.typeString {
            case "ferries":
                avoids.append(.ferries)
            case "highways":
                avoids.append(.highways)
            case "tolls":
                avoids.append(.tolls)
            case "indoor":
                avoids.append(.indoor)
            default:
                continue
            }
        }
    }
}
