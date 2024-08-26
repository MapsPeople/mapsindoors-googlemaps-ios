import Foundation
import GoogleMaps
import MapsIndoorsCore

/**
 #GMSCameraPosition Class Reference
 An immutable class that aggregates all camera position parameters.
 Inherited by GMSMutableCameraPosition.
 */

class GMCameraPosition: MPCameraPosition {
    func camera(target: CLLocationCoordinate2D, zoom: Float) -> MPCameraPosition? {
        let googleMutableCameraPosition = GMSMutableCameraPosition(target: target, zoom: zoom)
        return GMCameraPosition(cameraPosition: googleMutableCameraPosition)
    }

    var target: CLLocationCoordinate2D {
        googleCameraPosition?.target ?? CLLocationCoordinate2D()
    }

    var zoom: Float {
        googleCameraPosition?.zoom ?? 0
    }

    var bearing: CLLocationDirection {
        googleCameraPosition?.bearing ?? 0
    }

    var viewingAngle: Double {
        googleCameraPosition?.viewingAngle ?? 0
    }

    weak var googleCameraPosition: GMSCameraPosition?

    public required init(cameraPosition: GMSCameraPosition?) {
        googleCameraPosition = cameraPosition
    }
}
