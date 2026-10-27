import Foundation
@preconcurrency import GoogleMaps
@_spi(Private) import MapsIndoors
import MapsIndoorsCore

/// `@MainActor`: Google Maps delivers every `GMSMapViewDelegate` callback on the main thread, and the class
/// forwards to a host delegate and mutates the map view. Isolating it says so once instead of per callback.
@MainActor
class GoogleMapViewDelegate: NSObject, @preconcurrency GMSMapViewDelegate {
    weak var originalMapViewDelegate: GMSMapViewDelegate?
    weak var mapsIndoorsDelegate: MPMapProviderDelegate?
    var userGestureInProgress: Bool?
    weak var map: GoogleMapProvider?

    required init(googleMapProvider: GoogleMapProvider) {
        map = googleMapProvider
    }

    /**
     Google didTapMarker delegate
     Called after a marker has been tapped.
     */

    func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
        guard marker.isTappable else { return false }

        var result = false
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didTap:))) {
            result = originalMapViewDelegate.mapView?(mapView, didTap: marker) ?? false
        }

        // Retrieve the corresponding marker identifier
        let markerIdentifier = marker.locationId

        if let tag = marker.userData as? String, tag == "end_marker" || tag == "start_marker" || tag.starts(with: "stop") {
            map?.routeRenderer.routeMarkerDelegate?.onRouteMarkerClicked(tag: tag)
        }

        return mapsIndoorsDelegate?.didTap(locationId: markerIdentifier, type: .marker) ?? result
    }

    /**
     Google didTapAtCoordinate delegate
     Called after a tap gesture at a particular coordinate, but only if a marker was not tapped.
     This is called before deselecting any currently selected marker (the implicit action for tapping on the map).
     */

    func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didTapAt:))) {
            originalMapViewDelegate.mapView?(mapView, didTapAt: coordinate)
        }

        mapsIndoorsDelegate?.didTap(coordinate: coordinate)
    }

    /**
     Google willMove delegate
     Called before the camera on the map changes, either due to a gesture, animation (e.g., by a user tapping on the "My Location" button) or by being updated explicitly via the camera or a zero-length animation on layer.
     */

    func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
        userGestureInProgress = gesture

        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:willMove:))) {
            originalMapViewDelegate.mapView?(mapView, willMove: gesture)
        }
        if gesture {
            mapsIndoorsDelegate?.cameraWillMoveByUserGesture()
        }
        mapsIndoorsDelegate?.cameraWillMove()
    }

    func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:idleAt:))) {
            originalMapViewDelegate.mapView?(mapView, idleAt: position)
        }
        mapsIndoorsDelegate?.cameraIdle()
    }

    /**
     Google didChangeCameraPosition delegate
     Called repeatedly during any animations or gestures on the map (or once, if the camera is explicitly set).This may not be called for all intermediate camera positions. It is always called for the final position of an animation or gesture.
     */

    func mapView(_ mapView: GMSMapView, didChange position: GMSCameraPosition) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didChange:))) {
            originalMapViewDelegate.mapView?(mapView, didChange: position)
        }
        mapsIndoorsDelegate?.cameraChangedPosition()
    }

    /**
     Google didTapInfoWindowOfMarker delegate
     Called after a marker's info window has been tapped.
     */

    func mapView(_ mapView: GMSMapView, didTapInfoWindowOf marker: GMSMarker) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:markerInfoWindow:))) {
            originalMapViewDelegate.mapView?(mapView, didTapInfoWindowOf: marker)
        }

        if let id = marker.userData as? String {
            let _ = mapsIndoorsDelegate?.didTapInfoWindowOf(locationId: id)
        }
    }

    /**
     Google didBeginDraggingMarker delegate
     Called when dragging has been initiated on a marker.
     */

    func mapView(_ mapView: GMSMapView, didBeginDragging marker: GMSMarker) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didBeginDragging:))) {
            originalMapViewDelegate.mapView?(mapView, didBeginDragging: marker)
        }
    }

    /**
     Google didEndDraggingMarker delegate
     Called after dragging of a marker ended.
     */

    func mapView(_ mapView: GMSMapView, didEndDragging marker: GMSMarker) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didEndDragging:))) {
            originalMapViewDelegate.mapView?(mapView, didEndDragging: marker)
        }
    }

    /**
     Google didDragMarker delegate
     Called while a marker is dragged.
     */

    func mapView(_ mapView: GMSMapView, didDrag marker: GMSMarker) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didDrag:))) {
            originalMapViewDelegate.mapView?(mapView, didDrag: marker)
        }
    }

    /**
     Google mapViewDidStartTileRendering delegate
     Called when tiles have just been requested or labels have just started rendering.
     */

    func mapViewDidStartTileRendering(_ mapView: GMSMapView) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapViewDidStartTileRendering(_:))) {
            originalMapViewDelegate.mapViewDidStartTileRendering?(mapView)
        }
    }

    // This has to be updated to the one in mapControl
    /**
     Google mapViewDidFinishTileRendering delegate
     Called when all tiles have been loaded (or failed permanently) and labels have been rendered.
     */

    // JSON styling only needs to be loaded once
    private var didLoadStyling = false

    func mapViewDidFinishTileRendering(_ mapView: GMSMapView) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapViewDidFinishTileRendering(_:))) {
            originalMapViewDelegate.mapViewDidFinishTileRendering?(mapView)
        }

        // Fallback only — the provider applies this at construction. Kept because it is the one callback
        // guaranteed to fire even if the map view is handed over in an unusual state; `didLoadStyling`
        // makes it a no-op in the normal case.
        applyMapsPeopleStylingIfNeeded(to: mapView)
    }

    /// Applies the MapsPeople Google Maps styling, which is what removes Google's own POI icons.
    ///
    /// Idempotent, and deliberately callable before the map has rendered anything: the style is a JSON
    /// file in the bundle, so it needs no network and nothing has to have loaded first. It used to be
    /// applied from `mapViewDidFinishTileRendering`, which waits for *every tile to download and all
    /// labels to render* — measured at ~12 s on a cold start. The map was long since on screen by then,
    /// so applying the style blanked the whole map and removed a set of icons the user had been looking
    /// at for ten seconds. Applying it up front means Google's icons are never shown in the first place.
    func applyMapsPeopleStylingIfNeeded(to mapView: GMSMapView) {
        guard didLoadStyling == false else { return }

        // `MapsIndoorsBundle.bundle` resolves the framework's resource bundle by identifier. The
        // `Bundle.allBundles` scan this used to rely on only finds `MapsIndoors.bundle` once something
        // else has loaded it — which happens during the solution load, ~8 s into a cold start. So the
        // early attempts silently found nothing and the style landed long after the map was on screen,
        // stripping it in front of the user. `allBundles` is kept as a fallback, not the primary path.
        let candidates = [MapsIndoorsBundle.bundle].compactMap { $0 } + Bundle.allBundles
        for bundle in candidates {
            guard let styleUrl = bundle.url(forResource: "default_mapspeople_googlemaps_style", withExtension: "json"),
                let mapStyle = try? GMSMapStyle(contentsOfFileURL: styleUrl)
            else { continue }

            mapView.mapStyle = mapStyle
            didLoadStyling = true
            return
        }
    }

    /**
     Google didTapOverlay delegate
     Called after an overlay has been tapped.
     This method is not called for taps on markers.
     */

    func mapView(_ mapView: GMSMapView, didTap overlay: GMSOverlay) {
        guard overlay.isTappable else { return }

        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didTap:))) {
            originalMapViewDelegate.mapView?(mapView, didTap: overlay)
        }

        let id = overlay.locationId
        _ = mapsIndoorsDelegate?.didTap(locationId: id, type: overlay is GMSPolygon ? .polygon : .model2d)
    }

    /**
     Google didLongPressAtCoordinate delegate
     Called after a long-press gesture at a particular coordinate.
     */

    func mapView(_ mapView: GMSMapView, didLongPressAt coordinate: CLLocationCoordinate2D) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didLongPressAt:))) {
            originalMapViewDelegate.mapView?(mapView, didLongPressAt: coordinate)
        }
    }

    /**
     Google didLongPressInfoWindowOfMarker delegate
     Called after a marker's info window has been long pressed.
     */

    func mapView(_ mapView: GMSMapView, didLongPressInfoWindowOf marker: GMSMarker) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didLongPressInfoWindowOf:))) {
            originalMapViewDelegate.mapView?(mapView, didLongPressInfoWindowOf: marker)
        }
    }

    /**
     Google didTapMyLocationButtonForMapView delegate
     Called when the My Location button is tapped.
     */

    func didTapMyLocationButton(for mapView: GMSMapView) -> Bool {
        originalMapViewDelegate?.didTapMyLocationButton?(for: mapView) == nil
    }

    /**
     Google didTapMyLocation delegate
     Called when the My Location Dot is tapped.
     */

    func mapView(_ mapView: GMSMapView, didTapMyLocation location: CLLocationCoordinate2D) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didTapMyLocation:))) {
            originalMapViewDelegate.mapView?(mapView, didTapMyLocation: location)
        }
    }

    /**
     Google mapViewSnapshotReady delegate
     Called when map is stable (tiles loaded, labels rendered, camera idle) and overlay objects have been rendered.
     */

    func mapViewSnapshotReady(_ mapView: GMSMapView) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapViewSnapshotReady(_:))) {
            originalMapViewDelegate.mapViewSnapshotReady?(mapView)
        }
        mapsIndoorsDelegate?.cameraSnapshot()
    }

    /**
     Google didCloseInfoWindowOfMarker delegate
     Called when the marker's info window is closed.
     */

    func mapView(_ mapView: GMSMapView, didCloseInfoWindowOf marker: GMSMarker) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didCloseInfoWindowOf:))) {
            originalMapViewDelegate.mapView?(mapView, didCloseInfoWindowOf: marker)
        }
    }

    /**
     Google didTapPOIWithPlaceID delegate
     Called after a POI has been tapped.
     */

    func mapView(_ mapView: GMSMapView, didTapPOIWithPlaceID placeID: String, name: String, location: CLLocationCoordinate2D) {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:didTapPOIWithPlaceID:name:location:))) {
            originalMapViewDelegate.mapView?(mapView, didTapPOIWithPlaceID: placeID, name: name, location: location)
        }
    }

    /**
     Google markerInfoContents delegate
     Called when mapView:markerInfoWindow: returns nil.
     If this method returns a view, it will be placed within the default info window frame. If this method returns nil, then the default rendering will be used instead.
     */

    func mapView(_ mapView: GMSMapView, markerInfoContents marker: GMSMarker) -> UIView? {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:markerInfoContents:))) {
            if let infoWindow = originalMapViewDelegate.mapView?(mapView, markerInfoContents: marker) {
                return infoWindow
            }
        }
        return nil
    }

    /**
     Google markerInfoWindow delegate
     Called when a marker is about to become selected, and provides an optional custom info window to use for that marker if this method returns a UIView.
     If you change this view after this method is called, those changes will not necessarily be reflected in the rendered version.
     */

    func mapView(_ mapView: GMSMapView, markerInfoWindow marker: GMSMarker) -> UIView? {
        if let originalMapViewDelegate, originalMapViewDelegate.responds(to: #selector(GMSMapViewDelegate.mapView(_:markerInfoWindow:))) {
            if let infoWindow = originalMapViewDelegate.mapView?(mapView, markerInfoWindow: marker) {
                return infoWindow
            }
        }

        var res: UIView?
        if let id = marker.userData as? String {
            if let location = MPMapsIndoors.shared.locationWith(locationId: id) {
                res = map?.customInfoWindow?.infoWindowFor(location: location)
            }
        }
        return res
    }
}

extension GMSMarker {
    @objc fileprivate override var locationId: String {
        (userData as? String) ?? ""
    }
}

extension GMSOverlay {
    @objc fileprivate var locationId: String {
        (userData as? String) ?? ""
    }
}
