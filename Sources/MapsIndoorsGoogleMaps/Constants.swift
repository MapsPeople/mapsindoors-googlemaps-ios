/// The Z indices for MP specific`Overlays` a.k.a. Layers a.k.a. Content
enum MapOverlayZIndex: Int {
    case startMapsIndoorOverlays = 1_000_000
    case endMapsIndoorOverlays = 1_499_999

    case startFloorPlanRange = 1_000_001
    case endFloorPlanRange = 1_199_999

    case startPolygonsRange = 1_200_000
    case endPolygonsRange = 1_202_000

    case startModel2DRange = 1_202_001
    case endModel2DRange = 1_205_000

    case buildingOutlineHighlight = 1_300_000
    case locationOutlineHighlight = 1_300_010
    case directionsOverlays = 1_300_020

    case startMarkerOverlay = 1_300_100
    case endMarkerOverlay = 1_300_500

    // For the user location or `blue dot, starting index will be `positioningAccuracyCircle`and ending index will be `userLocationMarker`
    case positioningAccuracyCircle = 1_300_510
    case userLocationMarker = 1_300_520
}
