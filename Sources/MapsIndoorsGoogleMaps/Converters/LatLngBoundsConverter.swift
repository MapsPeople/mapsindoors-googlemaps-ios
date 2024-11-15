import Foundation
import GoogleMaps
import MapsIndoorsCore

public class LatLngBoundsConverter: NSObject {
    public class func convertToMPBounds(bounds: GMSCoordinateBounds) -> MPGeoBounds {
        MPGeoBounds(southWest: bounds.southWest, northEast: bounds.northEast)
    }

    public class func convertToGoogleBounds(bounds: MPGeoBounds) -> GMSCoordinateBounds {
        GMSCoordinateBounds(coordinate: bounds.northEast, coordinate: bounds.southWest)
    }
}
