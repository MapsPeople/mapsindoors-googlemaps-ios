import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

/// Every camera call is deferred by one hop even though the operator is already on the main actor: that is how
/// the class has always behaved (each method opened with a main-queue async), and callers such as the directions
/// renderer rely on the camera move landing after the current turn's map mutations. The hop is a main-actor
/// `Task`, which keeps that ordering without the main queue.
@MainActor
class GMCameraOperator: MPCameraOperator {
    private weak var map: GMSMapView?

    nonisolated required init(gmsView: GMSMapView?) {
        map = gmsView
    }

    func move(target: CLLocationCoordinate2D, zoom: Float) {
        Task { @MainActor in
            let position = GMSCameraPosition(
                latitude: target.latitude,
                longitude: target.longitude,
                zoom: zoom
            )
            self.map?.moveCamera(GMSCameraUpdate.setCamera(position))
        }
    }

    func animate(pos: MPCameraPosition) {
        // Lifted out here: `MPCameraPosition` is a MapsIndoors protocol with no Sendable story, and the closure
        // only needs the numbers.
        let target = pos.target
        let zoom = pos.zoom
        let bearing = pos.bearing
        let viewingAngle = pos.viewingAngle
        Task { @MainActor in
            let position = GMSCameraPosition(
                latitude: target.latitude,
                longitude: target.longitude,
                zoom: zoom,
                bearing: bearing,
                viewingAngle: viewingAngle
            )
            self.map?.animate(to: position)
        }
    }

    func animate(bounds: MPGeoBounds) {
        let northEast = bounds.northEast
        let southWest = bounds.southWest
        Task { @MainActor in
            let b = GMSCoordinateBounds(coordinate: northEast, coordinate: southWest)
            self.map?.animate(with: GMSCameraUpdate.fit(b))
        }
    }

    func animate(target: CLLocationCoordinate2D, zoom: Float?) {
        Task { @MainActor in
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
