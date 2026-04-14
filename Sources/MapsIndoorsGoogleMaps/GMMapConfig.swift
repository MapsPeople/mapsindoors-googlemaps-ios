import Foundation
import GoogleMaps
import MapsIndoorsCore

/// Extending MPMapConfig with an initializer for Google Maps
@objc extension MPMapConfig {
    public convenience init(gmsMapView: GMSMapView, googleApiKey: String) {
        self.init()
        mapProvider = GoogleMapProvider(mapView: gmsMapView, googleApiKey: googleApiKey)
    }
}
