import Foundation
import GoogleMaps
import MapsIndoorsCore

class GMCameraOperator: MPCameraOperator {
    private weak var map: GMSMapView?

    required init(gmsView: GMSMapView?) {
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
        @MainActor
        get async {
            GMProjection(projection: self.map?.projection)
        }
    }

    func camera(for bounds: MPGeoBounds, inserts: UIEdgeInsets) -> MPCameraPosition {
        var googleCameraForBounds = GMSCameraPosition()

        if Thread.isMainThread {
            let googleBound = GMSCoordinateBounds(coordinate: bounds.northEast, coordinate: bounds.southWest)
            googleCameraForBounds = map?.camera(for: googleBound, insets: inserts) ?? GMSCameraPosition(latitude: 0, longitude: 0, zoom: 5)
        } else {
            DispatchQueue.main.sync {
                let googleBound = GMSCoordinateBounds(coordinate: bounds.northEast, coordinate: bounds.southWest)
                googleCameraForBounds = self.map?.camera(for: googleBound, insets: inserts) ?? GMSCameraPosition(latitude: 0, longitude: 0, zoom: 5)
            }
        }

        let googleMutableCameraPosition = GMSMutableCameraPosition(target: googleCameraForBounds.target, zoom: googleCameraForBounds.zoom, bearing: googleCameraForBounds.bearing, viewingAngle: googleCameraForBounds.viewingAngle)
        return GMCameraPosition(cameraPosition: googleMutableCameraPosition)
    }
}
