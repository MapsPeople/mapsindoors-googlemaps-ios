import Foundation
import GoogleMaps
import MapsIndoorsCore

/**
 #GMSProjection Class Reference
 Defines a mapping between Earth coordinates (CLLocationCoordinate2D) and coordinates in the map's view (CGPoint).
 */

@MainActor
class GMProjection: MPProjection {
    private let projection: GMSProjection?

    required init(projection: GMSProjection?) {
        self.projection = projection
    }

    var visibleRegion: MPGeoRegion {
        get async {
            MPGeoRegion(
                nearLeft: projection?.visibleRegion().nearLeft ?? CLLocationCoordinate2D(),
                farLeft: projection?.visibleRegion().farLeft ?? CLLocationCoordinate2D(),
                farRight: projection?.visibleRegion().farRight ?? CLLocationCoordinate2D(),
                nearRight: projection?.visibleRegion().nearRight ?? CLLocationCoordinate2D())
        }
    }

    func coordinateFor(point: CGPoint) async -> CLLocationCoordinate2D {
        projection?.coordinate(for: point) ?? CLLocationCoordinate2D()
    }

    func pointFor(coordinate: CLLocationCoordinate2D) async -> CGPoint {
        projection?.point(for: coordinate) ?? .zero
    }
}
