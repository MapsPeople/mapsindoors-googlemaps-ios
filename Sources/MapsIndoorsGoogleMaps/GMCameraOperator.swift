import Foundation
import GoogleMaps
import MapsIndoorsCore

@MainActor
class GMCameraOperator: MPCameraOperator {
    private weak var map: GMSMapView?

    nonisolated required init(gmsView: GMSMapView?) {
        map = gmsView
    }

    func move(target: CLLocationCoordinate2D, zoom: Float) {
        DispatchQueue.main.async {
            let position = GMSCameraPosition(
                latitude: target.latitude,
                longitude: target.longitude,
                zoom: zoom
            )
            self.map?.moveCamera(GMSCameraUpdate.setCamera(position))
        }
    }

    func animate(pos: MPCameraPosition) {
        DispatchQueue.main.async {
            let position = GMSCameraPosition(
                latitude: pos.target.latitude,
                longitude: pos.target.longitude,
                zoom: pos.zoom,
                bearing: pos.bearing,
                viewingAngle: pos.viewingAngle
            )
            self.map?.animate(to: position)
        }
    }

    func animate(bounds: MPGeoBounds) {
        DispatchQueue.main.async {
            let b = GMSCoordinateBounds(coordinate: bounds.northEast, coordinate: bounds.southWest)
            self.map?.animate(with: GMSCameraUpdate.fit(b))
        }
    }

    func animate(target: CLLocationCoordinate2D, zoom: Float?) {
        DispatchQueue.main.async {
            let position = GMSCameraPosition(
                latitude: target.latitude,
                longitude: target.longitude,
                zoom: zoom ?? self.position.zoom
            )
            self.map?.animate(to: position)
        }
    }

    var position: MPCameraPosition {
        GMCameraPosition(cameraPosition: map?.camera)
    }

    var projection: MPProjection {
        get async {
            GMProjection(projection: self.map?.projection)
        }
    }

    func camera(for bounds: MPGeoBounds, inserts: UIEdgeInsets) -> MPCameraPosition {
        // `@MainActor` at the type level guarantees we run on the main thread,
        // so the previous `Thread.isMainThread` / `DispatchQueue.main.sync`
        // fallback is unreachable.
        let googleBound = GMSCoordinateBounds(coordinate: bounds.northEast, coordinate: bounds.southWest)
        let googleCameraForBounds = map?.camera(for: googleBound, insets: inserts) ?? GMSCameraPosition(latitude: 0, longitude: 0, zoom: 5)

        let googleMutableCameraPosition = GMSMutableCameraPosition(target: googleCameraForBounds.target, zoom: googleCameraForBounds.zoom, bearing: googleCameraForBounds.bearing, viewingAngle: googleCameraForBounds.viewingAngle)
        return GMCameraPosition(cameraPosition: googleMutableCameraPosition)
    }
}
