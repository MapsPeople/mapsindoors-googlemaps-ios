import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

/// Owns the blue-dot marker and accuracy circle on a Google map view. Main-actor isolated, because every field
/// is a Google Maps overlay; the `MPPositionPresenter` requirements are non-isolated and hop to the main actor
/// with a `Task`, where the main-queue async used to be.
@MainActor
final class GMPositionPresenter: MPPositionPresenter {
    private weak var map: GMSMapView!

    /// Internal (not `private`) so tests can observe what `apply` and `clear` put on, and take off, the map.
    let marker: GMSMarker
    let circle: GMSCircle

    required init(map: GMSMapView) {
        self.map = map

        marker = GMSMarker(position: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        circle = GMSCircle(position: CLLocationCoordinate2D(latitude: 0, longitude: 0), radius: 0)

        marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
        marker.isFlat = true
        marker.zIndex = Int32(MapOverlayZIndex.userLocationMarker.rawValue)
        circle.zIndex = Int32(MapOverlayZIndex.positioningAccuracyCircle.rawValue)
    }

    nonisolated func apply(
        position: CLLocationCoordinate2D,
        markerIcon: UIImage,
        markerBearing: Double,
        markerOpacity: Double,
        circleRadiusMeters: Double,
        circleFillColor: UIColor,
        circleStrokeColor: UIColor,
        circleStrokeWidth: Double
    ) {
        Task { @MainActor in
            self.applyOnMain(
                position: position,
                markerIcon: markerIcon,
                markerBearing: markerBearing,
                markerOpacity: markerOpacity,
                circleRadiusMeters: circleRadiusMeters,
                circleFillColor: circleFillColor,
                circleStrokeColor: circleStrokeColor,
                circleStrokeWidth: circleStrokeWidth)
        }
    }

    private func applyOnMain(
        position: CLLocationCoordinate2D,
        markerIcon: UIImage,
        markerBearing: Double,
        markerOpacity: Double,
        circleRadiusMeters: Double,
        circleFillColor: UIColor,
        circleStrokeColor: UIColor,
        circleStrokeWidth: Double
    ) {
        marker.position = position
        marker.icon = markerIcon
        marker.rotation = markerBearing
        marker.opacity = Float(markerOpacity)

        circle.position = position
        circle.radius = circleRadiusMeters
        circle.fillColor = circleFillColor
        circle.strokeColor = circleStrokeColor
        circle.strokeWidth = circleStrokeWidth

        if marker.map == nil {
            marker.map = map
        }

        if circle.map == nil {
            circle.map = map
        }
    }

    nonisolated func clear() {
        Task { @MainActor [weak self] in
            self?.marker.map = nil
            self?.circle.map = nil
        }
    }
}
