import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

/// The two camera verbs the operator uses, behind a protocol so a test can see which one a move took: a map view
/// that is not on screen sometimes lands an animation instantly, so the camera state cannot tell the animated
/// path from the instant one (SPEX-2060). `GMSMapView` has both verbs already.
@MainActor
protocol GMCameraDriving: AnyObject {
    func moveCamera(_ update: GMSCameraUpdate)
    func animate(with update: GMSCameraUpdate)
}

extension GMSMapView: GMCameraDriving {}

/// Every camera call is deferred by one hop even though the operator is already on the main actor: that is how
/// the class has always behaved (each method opened with a main-queue async), and callers such as the directions
/// renderer rely on the camera move landing after the current turn's map mutations. The hop is a main-actor
/// `Task`, which keeps that ordering without the main queue.
@MainActor
class GMCameraOperator: MPCameraOperator {
    private weak var map: GMSMapView?
    /// Test injection point for the camera verbs; `nil` drives the map view (SPEX-2060).
    var cameraDriverOverride: (any GMCameraDriving)?
    /// SAFETY: written only by the initialiser, before the operator is handed out, and read only on the main
    /// actor afterwards; `nonisolated(unsafe)` for the same reason as `MBCameraOperator.mapProvider`.
    private nonisolated(unsafe) weak var mapProvider: MPMapProvider?

    nonisolated required init(gmsView: GMSMapView?, provider: MPMapProvider? = nil) {
        map = gmsView
        mapProvider = provider
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
            self.apply(GMSCameraUpdate.setCamera(position))
        }
    }

    func animate(bounds: MPGeoBounds) {
        let northEast = bounds.northEast
        let southWest = bounds.southWest
        Task { @MainActor in
            let b = GMSCoordinateBounds(coordinate: northEast, coordinate: southWest)
            self.apply(GMSCameraUpdate.fit(b))
        }
    }

    func animate(target: CLLocationCoordinate2D, zoom: Float?) {
        Task { @MainActor in
            let position = GMSCameraPosition(
                latitude: target.latitude,
                longitude: target.longitude,
                zoom: zoom ?? self.position.zoom
            )
            self.apply(GMSCameraUpdate.setCamera(position))
        }
    }

    /// Animates `update` unless motion is not allowed for this map (host flag or Reduce Motion, see
    /// `MPCameraMotion`), in which case the camera is moved in place (SPEX-2060).
    private func apply(_ update: GMSCameraUpdate) {
        guard let driver: any GMCameraDriving = cameraDriverOverride ?? map else { return }
        if MPCameraMotion.shouldAnimate(for: mapProvider) {
            driver.animate(with: update)
        } else {
            driver.moveCamera(update)
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
