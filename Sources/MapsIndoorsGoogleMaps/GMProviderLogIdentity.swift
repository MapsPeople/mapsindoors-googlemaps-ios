import Foundation
import GoogleMaps
import MapsIndoorsCore

/// Identity sent to `MPLogger` by the MapsIndoors Google Maps provider so
/// uploaded log packages are tagged with Google Maps as the active map
/// framework and its SDK version as reported by `GMSServices`.
struct GMProviderLogIdentity: MPMapProviderLogIdentity {
    let component = "iOS GoogleMaps"

    // Captured once when this struct is constructed. Safe because
    // `GoogleMapProvider.init` receives an already-built `GMSMapView`, which
    // the host cannot create without having called `GMSServices.provideAPIKey`
    // first — so by the time we read the SDK version it's already resolved.
    let componentVersion: String = {
        let version = GMSServices.sdkVersion()
        return version.isEmpty ? "unknown" : version
    }()
}
