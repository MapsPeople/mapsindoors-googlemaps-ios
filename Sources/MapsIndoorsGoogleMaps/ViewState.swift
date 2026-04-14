import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore
import UIKit

/// This enum defines which state changeing operations we have.
/// There exists a state operation for each mutable characteristic of a view model's features (marker, polygon)
enum StateOperation {
    case markerVisibility
    case markerIcon
    case markerPosition
    case markerAnchor
    case markerClickable

    case polygonVisibility
    case polygonFillColor
    case polygonStrokeColor
    case polygonStrokeWidth
    case polygonGeometry
    case polygonClickable

    case floorplanVisibility
    case floorplanStrokeColor
    case floorplanStrokeWidth
    case floorplanFillColor
    case floorplanGeometry

    case infoWindow

    case model2dVisibility
    case model2dImage
    case model2dPosition
    case model2dBearing
    case model2dClickable
}

enum MarkerState {
    case undefined
    case invisible
    case visibleIcon
    case visibleLabel
    case visibleIconLabel

    var isVisible: Bool {
        !(self == .invisible)
    }

    var isIconVisible: Bool {
        self == .visibleIcon || self == .visibleIconLabel
    }

    var isLabelVisible: Bool {
        self == .visibleLabel || self == .visibleIconLabel
    }
}

enum Model2DState {
    case undefined
    case invisible
    case visible

    var isVisible: Bool {
        !(self == .invisible || self == .undefined)
    }
}

enum Constants {
    static let kMetersPerPixel = 0.014  // at 44°
}

enum PolygonState {
    case undefined
    case invisible
    case visible

    var isVisible: Bool {
        self == .visible
    }
}

/**
 This class is responsible for hosting map features (markers, polygons, etc.) and compare against a view model.
 If the "on-map" state of a feature differs from that of the view model, we compute a set of operations required to make the two states equal.
 */
actor ViewState {
    // Usefull debug flag, drawing a red box around a marker/label - which makes debugging collisions/clustering easier to visualize
    static let debugDrawImageBorder = false

    private weak var map: GMSMapView?
    let id: String

    var lastTimeTag = CFAbsoluteTimeGetCurrent()

    // This is a dictionary because state operations are idempotent so we only ever need to execute one
    private nonisolated let deltaOperations = LockedObject<[StateOperation: (GMSMapView?) -> Void]>(value: [:])

    nonisolated let marker = LockedObject<GMSMarker?>(value: nil)
    private nonisolated let polygons = LockedObject<[GMSPolygon]>(value: [])
    private nonisolated let floorPlanPolygons = LockedObject<[GMSPolygon]>(value: [])
    private nonisolated let overlay2D = LockedObject<GMSGroundOverlay?>(value: nil)
    private nonisolated let infoWindowAnchorPoint = LockedObject<CGPoint?>(value: nil)

    private var is2dModelsEnabled = false

    private var isFloorPlanEnabled = false

    nonisolated let shouldShowInfoWindowShadow = LockedObject<Bool>(value: false)
    var shouldShowInfoWindow: Bool = false {
        didSet {
            shouldShowInfoWindowShadow.value = shouldShowInfoWindow
            deltaOperations.value[.infoWindow] = { [weak self] map in
                DispatchQueue.main.sync {
                    if self?.shouldShowInfoWindowShadow.value ?? false, map?.selectedMarker != self?.marker.value {
                        map?.selectedMarker = self?.marker.value
                        if let anchor = self?.infoWindowAnchorPoint.value {
                            self?.marker.value?.infoWindowAnchor = anchor
                        }
                    }
                    if self?.shouldShowInfoWindowShadow.value ?? false == false {
                        if let selected = map?.selectedMarker {
                            if selected == self?.marker.value {
                                map?.selectedMarker = nil
                            }
                        }
                    }
                }
            }
        }
    }

    // Area of the underlying MapsIndoors Geometry (not necessarily related to the rendered geometry)
    nonisolated let poiArea = LockedObject<Double>(value: 0.0)

    private var imageBundle: IconLabelBundle?
    private var model2dBundle: Model2DBundle?

    // Enables forced rendering (for selection & highlight) - collision logic checks this flag
    nonisolated let forceRender = LockedObject<Bool>(value: false)

    nonisolated let infoWindowText = LockedObject<String?>(value: nil)

    // MARK: Marker

    func setMarkerState(state: MarkerState) {
        markerState = state
    }

    nonisolated let markerStateShadow = LockedObject<MarkerState>(value: .undefined)
    var markerState: MarkerState = .undefined {
        didSet {
            markerStateShadow.value = markerState
            switch markerState {
            case .visibleIconLabel:
                markerIcon = imageBundle?.both?.withDebugBox()
            case .visibleIcon:
                markerIcon = imageBundle?.icon?.withDebugBox()
            case .visibleLabel:
                markerIcon = imageBundle?.label?.withDebugBox()
            case .undefined, .invisible:
                break
            }

            deltaOperations.value[.markerVisibility] = { [weak self] map in
                DispatchQueue.main.sync {
                    switch self?.markerStateShadow.value {
                    case .visibleIconLabel, .visibleIcon, .visibleLabel:
                        self?.marker.value?.map = map
                    case .undefined, .invisible:
                        self?.marker.value?.map = nil
                    case .none:
                        return
                    }
                }
            }
        }
    }

    nonisolated let markerAnchorShadow = LockedObject<CGPoint>(value: CGPoint(x: 0.5, y: 0.5))
    var markerAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5) {
        didSet {
            markerAnchorShadow.value = markerAnchor
            deltaOperations.value[.markerAnchor] = { [weak self] _ in
                DispatchQueue.main.sync {
                    guard self?.marker.value?.groundAnchor != self?.markerAnchorShadow.value else { return }
                    self?.marker.value?.groundAnchor = self?.markerAnchorShadow.value ?? CGPoint(x: 0.5, y: 0.5)
                }
            }
        }
    }

    nonisolated let markerPositionShadow = LockedObject<CLLocationCoordinate2D?>(value: nil)
    var markerPosition: CLLocationCoordinate2D? {
        didSet {
            markerPositionShadow.value = markerPosition
            deltaOperations.value[.markerPosition] = { [weak self] _ in
                DispatchQueue.main.sync {
                    guard let markerPosition = self?.markerPositionShadow.value, self?.marker.value?.position != markerPosition else { return }
                    self?.marker.value?.position = markerPosition
                }
            }
        }
    }

    nonisolated let markerIconShadow = LockedObject<UIImage?>(value: nil)
    var markerIcon: UIImage? {
        didSet {
            markerIconShadow.value = markerIcon
            deltaOperations.value[.markerIcon] = { [weak self] _ in
                DispatchQueue.main.sync {
                    guard self?.marker.value?.icon != self?.markerIconShadow.value, self?.markerIconShadow.value != nil else { return }
                    self?.marker.value?.icon = self?.markerIconShadow.value
                }
            }
        }
    }

    nonisolated let markerClickableShadow = LockedObject<Bool>(value: false)
    var markerClickable: Bool = false {
        didSet {
            markerClickableShadow.value = markerClickable
            deltaOperations.value[.markerClickable] = { [weak self] _ in
                DispatchQueue.main.sync {
                    self?.marker.value?.isTappable = self?.markerClickableShadow.value ?? false
                }
            }
        }
    }

    // MARK: floorPlan
    nonisolated let floorPlanStateShadow = LockedObject<PolygonState>(value: .undefined)
    var floorPlanState: PolygonState = .undefined {
        didSet {
            floorPlanStateShadow.value = floorPlanState
            deltaOperations.value[.floorplanVisibility] = { [weak self] map in
                DispatchQueue.main.sync {
                    switch self?.floorPlanStateShadow.value {
                    case .visible:
                        for wall in self?.floorPlanPolygons.value ?? [] {
                            wall.map = map
                        }
                    case .undefined, .invisible:
                        for wall in self?.floorPlanPolygons.value ?? [] {
                            wall.map = nil
                        }
                    case .none:
                        return
                    }
                }
            }
        }
    }

    nonisolated let floorPlanStrokeColorShadow = LockedObject<UIColor?>(value: nil)
    var floorPlanStrokeColor: UIColor? {
        didSet {
            floorPlanStrokeColorShadow.value = floorPlanStrokeColor
            deltaOperations.value[.floorplanStrokeColor] = { [weak self] _ in
                DispatchQueue.main.sync {
                    for floorPlan in self?.floorPlanPolygons.value ?? [] {
                        floorPlan.strokeColor = self?.floorPlanStrokeColorShadow.value
                    }
                }
            }
        }
    }

    nonisolated let floorPlanStrokeWidthShadow = LockedObject<Double?>(value: nil)
    var floorPlanStrokeWidth: Double? {
        didSet {
            floorPlanStrokeWidthShadow.value = floorPlanStrokeWidth
            deltaOperations.value[.floorplanStrokeWidth] = { [weak self] _ in
                DispatchQueue.main.sync {
                    for floorPlan in self?.floorPlanPolygons.value ?? [] {
                        floorPlan.strokeWidth = CGFloat(self?.floorPlanStrokeWidthShadow.value ?? 0.0)
                    }
                }
            }
        }
    }

    nonisolated let floorPlanFillColorShadow = LockedObject<UIColor?>(value: nil)
    var floorPlanFillColor: UIColor? {
        didSet {
            floorPlanFillColorShadow.value = floorPlanFillColor
            deltaOperations.value[.floorplanFillColor] = { [weak self] _ in
                DispatchQueue.main.sync {
                    for floorPlan in self?.floorPlanPolygons.value ?? [] {
                        floorPlan.fillColor = self?.floorPlanFillColorShadow.value
                    }
                }
            }
        }
    }

    nonisolated let floorPlanGeometriesShadow = LockedObject<[GMSPath]>(value: [])
    var floorPlanGeometries: [GMSPath]? {
        didSet {
            floorPlanGeometriesShadow.value = floorPlanGeometries ?? []
            deltaOperations.value[.floorplanGeometry] = { [weak self] map in
                DispatchQueue.main.sync {
                    let upper = Double(MapOverlayZIndex.endFloorPlanRange.rawValue)
                    let lower = Double(MapOverlayZIndex.startFloorPlanRange.rawValue)
                    let zindex = (abs(upper - (self?.poiArea.value ?? 0.0)).truncatingRemainder(dividingBy: lower) + lower) - 1  // -1 to ensure it is rendered below regular polygon geometry

                    guard let floorPlanGeometries = self?.floorPlanGeometriesShadow.value, zindex.isFinite, zindex.isNaN == false else { return }
                    for geometry in floorPlanGeometries {
                        if self?.floorPlanPolygons.value.contains(where: { $0.path?.encodedPath() == geometry.encodedPath() }) ?? true { continue }

                        let floorPlanPolygon = GMSPolygon(path: geometry)

                        // To avoid having the polygon briefly with its default blue color, before our logic updates it (causes flashing) - we set a transparent color here
                        floorPlanPolygon.fillColor = self?.floorPlanFillColorShadow.value ?? .red.withAlphaComponent(0.0)
                        floorPlanPolygon.strokeColor = self?.floorPlanStrokeColorShadow.value ?? .red.withAlphaComponent(0.0)
                        floorPlanPolygon.strokeWidth = self?.floorPlanStrokeWidthShadow.value ?? 0.0
                        floorPlanPolygon.zIndex = Int32(Int(zindex))
                        self?.floorPlanPolygons.value.append(floorPlanPolygon)

                        // In order for the updated geometry to be reflected, we need to remove/re-add the map
                        if self?.floorPlanStateShadow.value.isVisible ?? false {
                            floorPlanPolygon.map = map
                        }
                    }
                }
            }
        }
    }

    // MARK: Polygon
    nonisolated let polygonStateShadow = LockedObject<PolygonState>(value: .undefined)
    var polygonState: PolygonState = .undefined {
        didSet {
            polygonStateShadow.value = polygonState
            deltaOperations.value[.polygonVisibility] = { [weak self] map in
                DispatchQueue.main.sync {
                    for polygon in self?.polygons.value ?? [] {
                        polygon.userData = self?.id
                    }
                    switch self?.polygonStateShadow.value {
                    case .visible:
                        for polygon in self?.polygons.value ?? [] {
                            polygon.map = map
                        }
                    case .undefined, .invisible:
                        for polygon in self?.polygons.value ?? [] {
                            polygon.map = nil
                        }
                    case .none:
                        return
                    }
                }
            }
        }
    }

    nonisolated let polygonFillColorShadow = LockedObject<UIColor?>(value: nil)
    var polygonFillColor: UIColor? {
        didSet {
            polygonFillColorShadow.value = polygonFillColor
            deltaOperations.value[.polygonFillColor] = { [weak self] _ in
                DispatchQueue.main.sync {
                    for polygon in self?.polygons.value ?? [] {
                        polygon.fillColor = self?.polygonFillColorShadow.value
                    }
                }
            }
        }
    }

    nonisolated let polygonStrokeColorShadow = LockedObject<UIColor?>(value: nil)
    var polygonStrokeColor: UIColor? {
        didSet {
            polygonStrokeColorShadow.value = polygonStrokeColor
            deltaOperations.value[.polygonStrokeColor] = { [weak self] _ in
                DispatchQueue.main.sync {
                    for polygon in self?.polygons.value ?? [] {
                        polygon.strokeColor = self?.polygonStrokeColorShadow.value
                    }
                }
            }
        }
    }

    nonisolated let polygonStrokeWidthShadow = LockedObject<Double?>(value: nil)
    var polygonStrokeWidth: Double? {
        didSet {
            polygonStrokeWidthShadow.value = polygonStrokeWidth
            deltaOperations.value[.polygonStrokeWidth] = { [weak self] _ in
                DispatchQueue.main.sync {
                    for polygon in self?.polygons.value ?? [] {
                        polygon.strokeWidth = CGFloat(self?.polygonStrokeWidthShadow.value ?? 0.0)
                    }
                }
            }
        }
    }

    nonisolated let polygonGeometriesShadow = LockedObject<[GMSPath]>(value: [])
    var polygonGeometries: [GMSPath]? {
        didSet {
            polygonGeometriesShadow.value = polygonGeometries ?? []
            deltaOperations.value[.polygonGeometry] = { [weak self] map in
                DispatchQueue.main.sync {
                    let upper = Double(MapOverlayZIndex.endPolygonsRange.rawValue)
                    let lower = Double(MapOverlayZIndex.startPolygonsRange.rawValue)
                    let zindex = abs(upper - (self?.poiArea.value ?? 0)).truncatingRemainder(dividingBy: lower) + lower

                    guard let polygonGeometries = self?.polygonGeometriesShadow.value, zindex.isFinite, zindex.isNaN == false else { return }
                    for geometry in polygonGeometries {
                        if self?.polygons.value.contains(where: { $0.path?.encodedPath() == geometry.encodedPath() }) ?? true { continue }

                        let polygon = GMSPolygon(path: geometry)

                        // To avoid having the polygon briefly with its default blue color, before our logic updates it (causes flashing) - we set a transparent color here
                        polygon.fillColor = self?.polygonFillColorShadow.value ?? .red.withAlphaComponent(0.0)
                        polygon.strokeColor = self?.polygonStrokeColorShadow.value ?? .red.withAlphaComponent(0.0)
                        polygon.strokeWidth = self?.polygonStrokeWidthShadow.value ?? 0.0
                        polygon.zIndex = Int32(Int(zindex))
                        self?.polygons.value.append(polygon)

                        // In order for the updated geometry to be reflected, we need to remove/re-add the map
                        if self?.polygonStateShadow.value.isVisible ?? false {
                            polygon.map = map
                        }
                    }
                }
            }
        }
    }

    nonisolated let polygonClickableShadow = LockedObject<Bool>(value: false)
    var polygonClickable: Bool = false {
        didSet {
            polygonClickableShadow.value = polygonClickable
            deltaOperations.value[.polygonClickable] = { [weak self] _ in
                DispatchQueue.main.sync {
                    for polygon in self?.polygons.value ?? [] {
                        polygon.isTappable = self?.polygonClickableShadow.value ?? false
                    }
                }
            }
        }
    }

    // MARK: 2D Model

    private nonisolated let model2DStateShadow = LockedObject<Model2DState>(value: .undefined)
    private var model2DState: Model2DState = .undefined {
        didSet {
            model2DStateShadow.value = model2DState
            if oldValue != model2DState {
                deltaOperations.value[.model2dVisibility] = { [weak self] map in
                    DispatchQueue.main.sync {
                        switch self?.model2DStateShadow.value {
                        case .visible:
                            self?.overlay2D.value?.map = map
                        case .undefined, .invisible:
                            self?.overlay2D.value?.map = nil
                        case .none:
                            return
                        }
                    }
                }
            }
        }
    }

    private nonisolated let model2DPositionShadow = LockedObject<CLLocationCoordinate2D?>(value: nil)
    private var model2DPosition: CLLocationCoordinate2D? {
        didSet {
            model2DPositionShadow.value = model2DPosition
            deltaOperations.value[.model2dPosition] = { [weak self] _ in
                DispatchQueue.main.sync {
                    guard let model2DPosition = self?.model2DPositionShadow.value, self?.overlay2D.value?.position != model2DPosition else { return }
                    self?.overlay2D.value?.position = model2DPosition
                }
            }
        }
    }

    private nonisolated let model2DImageShadow = LockedObject<UIImage?>(value: nil)
    private var model2DImage: UIImage? {
        didSet {
            model2DImageShadow.value = model2DImage
            deltaOperations.value[.model2dImage] = { [weak self] _ in
                DispatchQueue.main.sync {
                    var bounds: GMSCoordinateBounds?
                    if let model2DSouthWest = self?.model2DPositionShadow.value {
                        let model2DSouthEast = GMSGeometryOffset(model2DSouthWest, self?.model2DWidthMeters.value ?? 0, 90)
                        let model2DNorthEast = GMSGeometryOffset(model2DSouthEast, self?.model2DHeightMeters.value ?? 0, 0)
                        bounds = GMSCoordinateBounds(coordinate: model2DSouthWest, coordinate: model2DNorthEast)
                    }

                    self?.overlay2D.value?.bounds = bounds
                    self?.overlay2D.value?.icon = self?.model2DImageShadow.value

                    let upper = Double(MapOverlayZIndex.endModel2DRange.rawValue)
                    let lower = Double(MapOverlayZIndex.startModel2DRange.rawValue)
                    let zindex = abs(upper - (self?.poiArea.value ?? 0.0)).truncatingRemainder(dividingBy: lower) + lower
                    self?.overlay2D.value?.zIndex = Int32(zindex)
                }
            }
        }
    }

    private nonisolated let model2DBearingShadow = LockedObject<Double?>(value: nil)
    private var model2DBearing: Double? {
        didSet {
            model2DBearingShadow.value = model2DBearing
            if oldValue != model2DBearing {
                deltaOperations.value[.model2dBearing] = { [weak self] _ in
                    DispatchQueue.main.sync {
                        self?.overlay2D.value?.bearing = self?.model2DBearingShadow.value ?? 0.0
                    }
                }
            }
        }
    }

    private nonisolated let model2DClickableShadow = LockedObject<Bool>(value: false)
    var model2DClickable: Bool = false {
        didSet {
            model2DClickableShadow.value = model2DClickable
            deltaOperations.value[.model2dClickable] = { [weak self] _ in
                DispatchQueue.main.sync {
                    self?.overlay2D.value?.isTappable = self?.model2DClickableShadow.value ?? false
                }
            }
        }
    }

    var iconSize = CGSize.zero
    var labelSize = CGSize.zero

    @MainActor
    var bounds: CGRect? {
        get async {
            guard let mapView = await map, await markerState.isVisible, let markerPos = await markerPosition, await markerIcon != nil else { return nil }
            var rect: CGRect?

            let p = mapView.projection.point(for: markerPos)
            if let size = await imageBundle?.getSize(state: markerState) {
                let x = await p.x - (size.width * markerAnchor.x)
                let y = await p.y - (size.height * markerAnchor.y)
                rect = CGRect(x: x.rounded(.down), y: y.rounded(.down), width: size.width.rounded(.down), height: size.height.rounded(.down))
            }

            return rect
        }
    }

    private nonisolated let model2DWidthMeters = LockedObject<Double>(value: 0.0)
    private nonisolated let model2DHeightMeters = LockedObject<Double>(value: 0.0)

    private var latestModel: (any MPViewModel)?

    @MainActor
    init(viewModel: any MPViewModel, map: GMSMapView, is2dModelEnabled: Bool, isFloorPlanEnabled: Bool) async {
        id = viewModel.id
        self.map = map
        self.latestModel = viewModel

        await marker.value = GMSMarker(position: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        await marker.value?.zIndex = Int32(MapOverlayZIndex.startMarkerOverlay.rawValue)
        await overlay2D.value = GMSGroundOverlay(bounds: nil, icon: nil)
        await polygons.value = [GMSPolygon]()

        is2dModelsEnabled = is2dModelEnabled
        self.isFloorPlanEnabled = isFloorPlanEnabled

        await marker.value?.userData = id
        await overlay2D.value?.userData = id
    }

    func calculateMarkerAnchor(markerSize: Double, iconSize: Double, anchor: Double) -> Double {
        (iconSize * anchor) / markerSize
    }

    /// If the view state is no longer in view, it may still be cached - but we remove the marker icon, to ease the memory load on the Maps SDK
    func setMarkedAsNoLongerInView() {
        self.markerIcon = nil
        self.model2DImage = nil
    }

    /// Computes the set of state operations required to have the view state's properties reflect those in the view model.
    /// This is done by assigning model values to the view state's corresponding property. Upon each property assignment, it check
    /// whether the value has changed - and a function is created to accommodate this change property and reflect the changes on corresponding map feature.
    func computeDelta(newModel: any MPViewModel) {
        lastTimeTag = CFAbsoluteTimeGetCurrent()
        deltaOperations.value.removeAll()
        infoWindowText.value = newModel.marker?.properties[.markerLabelInfoWindow] as? String
        markerState = newModel.markerState

        computeMarkerState(newModel: newModel)

        shouldShowInfoWindow = newModel.showInfoWindow

        polygonState = newModel.polygonState
        if polygonState.isVisible || polygonState == .undefined {
            if let fillColor = newModel.polygonFillColor {
                polygonFillColor = fillColor
            }
            if let strokeColor = newModel.polygonStrokeColor {
                polygonStrokeColor = strokeColor
            }
            if let strokeWidth = newModel.polygonStrokeWidth {
                polygonStrokeWidth = strokeWidth
            }
            polygonGeometries = newModel.polygonGeometries
            polygonClickable = newModel.polygon?.properties[.clickable] as? Bool ?? false
        }

        if isFloorPlanEnabled {
            floorPlanState = newModel.floorPlanState
            if floorPlanState.isVisible || floorPlanState == .undefined {
                floorPlanStrokeColor = newModel.floorPlanStrokeColor
                floorPlanStrokeWidth = newModel.floorPlanStrokeWidth
                floorPlanFillColor = newModel.floorPlanFillColor
                floorPlanGeometries = newModel.floorPlanGeometries
            }
        }

        if is2dModelsEnabled {
            model2DState = newModel.model2DState
            if model2DState.isVisible || model2DState == .undefined {
                if let bundle = newModel.model2DBundle {
                    if let mapView = map, let image = bundle.icon {
                        let zoom = Int(mapView.camera.zoom)
                        let scaleFactor =
                            switch zoom {
                            case 21: 1.0
                            case 20: 0.9
                            case 19: 0.6
                            case 18: 0.4
                            case 17: 0.2
                            default:
                                0.1
                            }

                        let newMaxDimension = max(image.size.width, image.size.height) * CGFloat(scaleFactor)

                        let scaledImage = image.downSize(to: newMaxDimension)

                        model2DImage = scaledImage
                    }

                    model2dBundle = bundle
                    model2DWidthMeters.value = bundle.widthMeters
                    model2DHeightMeters.value = bundle.heightMeters
                }

                if let position = newModel.model2DPosition {
                    model2DPosition = position
                }

                if let bearing = newModel.model2DBearing {
                    model2DBearing = bearing
                }

                model2DClickable = newModel.model2D?.properties[.clickable] as? Bool ?? false
            }
        }
    }

    private func computeMarkerState(newModel: any MPViewModel) {
        if markerState.isVisible || markerState == .undefined {
            if let bundle = newModel.iconLabelBundle {
                if let image = bundle.both {
                    markerIcon = image
                }
                imageBundle = bundle
                iconSize = bundle.iconSize
                labelSize = bundle.labelSize
                markerClickable = newModel.marker?.properties[.clickable] as? Bool ?? false

                if newModel.marker?.properties[.isCollidable] as? Bool ?? true == false {
                    forceRender.value = true
                } else {
                    forceRender.value = false
                }

                if let size = bundle.getSize(state: .visibleIconLabel) {
                    let anchorX = calculateMarkerAnchor(markerSize: size.width, iconSize: bundle.iconSize.width, anchor: 0.5)

                    if markerState.isIconVisible, markerState.isLabelVisible {
                        markerAnchor = CGPoint(x: anchorX, y: 0.5)
                        infoWindowAnchorPoint.value = CGPoint(x: anchorX, y: 0)
                        DispatchQueue.main.async {
                            if newModel.marker?.properties[.isCollidable] as? Bool == false {
                                if self.markerState.isLabelVisible || self.markerState.isIconVisible {
                                    self.infoWindowAnchorPoint.value = CGPoint(x: anchorX, y: 0)
                                }
                            }
                        }
                    } else if markerState.isIconVisible {
                        markerAnchor = CGPoint(x: 0.5, y: 0.5)
                    } else if markerState.isLabelVisible {
                        markerAnchor = CGPoint(x: 0.5, y: 0.5)
                    }

                    if markerState.isIconVisible, markerState.isLabelVisible {
                        DispatchQueue.main.async {
                            self.marker.value?.infoWindowAnchor = CGPoint(x: anchorX, y: 0)
                        }

                        if let iconPlacement = newModel.marker?.properties[.markerIconPlacement] as? String,
                            let labelPlacement = newModel.marker?.properties[.labelAnchor] as? String
                        {
                            switch iconPlacement {
                            case "bottom":
                                switch labelPlacement {
                                case "top":
                                    markerAnchor = CGPoint(x: 0.5, y: ratio(a: labelSize.height, b: iconSize.height))
                                default:
                                    markerAnchor = CGPoint(x: anchorX, y: 1.0)
                                }
                            case "top":
                                markerAnchor = CGPoint(x: anchorX, y: 0.0)
                            case "left":
                                markerAnchor = CGPoint(x: 0.0, y: 0.5)
                            case "right":
                                markerAnchor = CGPoint(x: anchorX * 2, y: 0.5)
                            case "center":
                                fallthrough
                            default:
                                markerAnchor = CGPoint(x: anchorX, y: 0.5)
                            }
                        }
                    } else if markerState.isIconVisible {
                        DispatchQueue.main.async {
                            self.marker.value?.infoWindowAnchor = CGPoint(x: 0.5, y: 0)
                        }

                        if let iconPlacement = newModel.marker?.properties[.markerIconPlacement] as? String {
                            switch iconPlacement {
                            case "bottom":
                                markerAnchor = CGPoint(x: 0.5, y: 1.0)
                            case "top":
                                markerAnchor = CGPoint(x: 0.5, y: 0.0)
                            case "left":
                                markerAnchor = CGPoint(x: 0.0, y: 0.5)
                            case "right":
                                markerAnchor = CGPoint(x: 1.0, y: 0.5)
                            case "center":
                                fallthrough
                            default:
                                markerAnchor = CGPoint(x: 0.5, y: 0.5)
                            }
                        }
                    }
                }
            }
            markerPosition = newModel.markerPosition
            if let area = newModel.marker?.properties[.markerGeometryArea] {
                poiArea.value = area as? Double ?? 0.0
            }
        }
    }

    private func ratio(a: Double, b: Double) -> Double {
        min(a, b) / max(a, b)
    }

    /// Executes the set of state operations, computed to "catch up" with the state of the latest view model
    func applyDelta() async {
        let renderOperationsInOrder: [StateOperation] = [
            .markerAnchor,
            .markerIcon,
            .markerVisibility,
            .markerPosition,
            .markerClickable,
            .infoWindow,
            .polygonStrokeWidth,
            .polygonFillColor,
            .polygonStrokeColor,
            .polygonVisibility,
            .polygonGeometry,
            .polygonClickable,
            .floorplanStrokeWidth,
            .floorplanStrokeColor,
            .floorplanVisibility,
            .floorplanGeometry,
            .model2dImage,
            .model2dBearing,
            .model2dVisibility,
            .model2dPosition,
            .model2dClickable,
        ]

        for operationType in renderOperationsInOrder {
            if let operation = deltaOperations.value[operationType] {
                operation(self.map)
            }
        }
    }

    /// Removes all map features from the mapview
    @MainActor
    func destroy() async {
        marker.value?.icon = nil
        marker.value?.map = nil
        overlay2D.value?.icon = nil
        overlay2D.value?.map = nil
        for polygon in polygons.value {
            polygon.map = nil
        }
        for polygon in floorPlanPolygons.value {
            polygon.map = nil
        }
        deltaOperations.value.removeAll()
    }
}

class Model2DBundle {
    let icon: UIImage?

    let widthMeters: Double
    let heightMeters: Double

    required init(icon: UIImage?, widthMeters: Double, heightMeters: Double) {
        self.icon = icon
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
    }
}

class IconLabelBundle {
    let icon: UIImage?
    let label: UIImage?
    let iconSize: CGSize
    let labelSize: CGSize
    var both: UIImage?

    required init(icon: UIImage?, label: UIImage?, labelPosition: MPLabelPosition = .right) {
        self.icon = icon
        self.label = label
        iconSize = icon?.size ?? CGSize.zero
        labelSize = label?.size ?? CGSize.zero
        if let compiled = compile(icon: icon, label: label, position: labelPosition) {
            both = compiled
        }
    }

    func getSize(state: MarkerState) -> CGSize? {
        switch state {
        case .invisible:
            nil
        case .visibleIcon:
            iconSize
        case .visibleLabel:
            labelSize
        case .visibleIconLabel:
            both?.size
        default:
            nil
        }
    }

    private func compile(icon: UIImage?, label: UIImage?, position: MPLabelPosition) -> UIImage? {
        let respectDistance = CGFloat(3)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false  // true = no alpha channel, for debugging

        // Early return if neither are set
        guard let icon, let label else {
            return icon?.withDebugBox() ?? label?.withDebugBox()
        }

        let box: CGRect
        switch position {
        case .top, .bottom:
            let width = max(icon.size.width, label.size.width)
            let height = icon.size.height + label.size.height + respectDistance
            box = CGRect(x: 0, y: 0, width: width, height: height)
        case .left, .right:
            let width = icon.size.width + label.size.width + respectDistance
            let height = max(icon.size.height, label.size.height)
            box = CGRect(x: 0, y: 0, width: width, height: height)
        }

        guard box.size != .zero else { return nil }

        let renderer = UIGraphicsImageRenderer(size: box.size, format: format)
        return renderer.image { _ in
            switch position {
            case .top:
                icon.draw(at: CGPoint(x: (box.width - icon.size.width) / 2, y: label.size.height + respectDistance))
                label.draw(at: CGPoint(x: (box.width - label.size.width) / 2, y: 0))
            case .bottom:
                icon.draw(at: CGPoint(x: (box.width - icon.size.width) / 2, y: 0))
                label.draw(at: CGPoint(x: (box.width - label.size.width) / 2, y: icon.size.height + respectDistance))
            case .left:
                icon.draw(at: CGPoint(x: label.size.width + respectDistance, y: (box.height - icon.size.height) / 2))
                label.draw(at: CGPoint(x: 0, y: (box.height - label.size.height) / 2))
            case .right:
                icon.draw(at: CGPoint(x: 0, y: (box.height - icon.size.height) / 2))
                label.draw(at: CGPoint(x: icon.size.width + respectDistance, y: (box.height - label.size.height) / 2))
            }
        }.withDebugBox()
    }
}

/// Convenience extensions for view models, useful in the ViewState class' logic
extension MPViewModel {
    var markerState: MarkerState {
        if let feature = marker {
            let hasLabel = feature.properties[.markerLabel] != nil
            let hasIcon = (data[.icon] as? UIImage) != nil
            if hasIcon, hasLabel {
                return .visibleIconLabel
            }
            if hasIcon {
                return .visibleIcon
            }
            if hasLabel {
                return .visibleLabel
            }
        }
        return .invisible
    }

    var markerPosition: CLLocationCoordinate2D? {
        if let point = marker?.geometry.coordinates as? MPPoint {
            return point.coordinate
        }
        return nil
    }

    var polygonState: PolygonState {
        if let feature = polygon {
            let hasGeometry = polygonGeometries.isEmpty == false
            let hasArea = feature.properties[.polygonArea] as? Double != nil
            if hasGeometry, hasArea {
                return .visible
            } else {
                return .invisible
            }
        }
        return .invisible
    }

    var polygonGeometries: [GMSPath] {
        var geometries = [GMSPath]()

        if polygon?.geometry.type == .Polygon {
            for polygon in polygon?.geometry.coordinates as? [[MPPoint]] ?? [] {
                let path = GMSMutablePath()
                for pathPoint in polygon {
                    path.add(pathPoint.coordinate)
                }
                geometries.append(path)
            }
        }

        if polygon?.geometry.type == .MultiPolygon {
            for polygons in polygon?.geometry.coordinates as? [MPPolygonGeometry] ?? [] {
                for polygon in polygons.coordinates {
                    let path = GMSMutablePath()
                    for pathPoint in polygon {
                        path.add(pathPoint.coordinate)
                    }
                    geometries.append(path)
                }
            }
        }

        return geometries
    }

    var floorPlanState: PolygonState {
        let hasfloorPlan = floorPlanGeometries.isEmpty == false
        if hasfloorPlan {
            return .visible
        } else {
            return .invisible
        }
    }

    var floorPlanGeometries: [GMSPath] {
        var geometries = [GMSPath]()

        if floorPlanExtrusion?.geometry.type == .Polygon {
            for polygon in floorPlanExtrusion?.geometry.coordinates as? [[MPPoint]] ?? [] {
                let path = GMSMutablePath()
                for pathPoint in polygon {
                    path.add(pathPoint.coordinate)
                }
                geometries.append(path)
            }
        }

        if floorPlanExtrusion?.geometry.type == .MultiPolygon {
            for polygons in floorPlanExtrusion?.geometry.coordinates as? [MPPolygonGeometry] ?? [] {
                for polygon in polygons.coordinates {
                    let path = GMSMutablePath()
                    for pathPoint in polygon {
                        path.add(pathPoint.coordinate)
                    }
                    geometries.append(path)
                }
            }
        }

        return geometries
    }

    var floorPlanFillColor: UIColor? {
        if let colorHex = floorPlanExtrusion?.properties[.floorPlanFillColorAlpha] as? String {
            return UIColor(hex: colorHex)
        }
        return nil
    }

    var floorPlanStrokeColor: UIColor? {
        if let colorHex = floorPlanExtrusion?.properties[.floorPlanStrokeColorAlpha] as? String {
            return UIColor(hex: colorHex)
        }
        return nil
    }

    var floorPlanStrokeWidth: Double? {
        floorPlanExtrusion?.properties[.floorPlanStrokeWidth] as? Double
    }

    var polygonFillColor: UIColor? {
        if let colorHex = polygon?.properties[.polygonFillcolorAlpha] as? String {
            return UIColor(hex: colorHex)
        }
        return nil
    }

    var polygonStrokeColor: UIColor? {
        if let colorHex = polygon?.properties[.polygonStrokeColorAlpha] as? String {
            return UIColor(hex: colorHex)
        }
        return nil
    }

    var polygonStrokeWidth: Double? {
        polygon?.properties[.polygonStrokeWidth] as? Double
    }

    var iconLabelBundle: IconLabelBundle? {
        let labelImage = computedLabelImage
        let iconImage = data[.icon] as? UIImage

        var labelPosition: MPLabelPosition = .right

        if let position = marker?.properties[.labelAnchor] as? String {
            labelPosition =
                switch position {
                case "left":
                    .right
                case "top":
                    .bottom
                case "bottom":
                    .top
                default:
                    .left
                }
        }

        return IconLabelBundle(icon: iconImage, label: labelImage, labelPosition: labelPosition)
    }

    // MARK: 2D Model

    var model2DBundle: Model2DBundle? {
        Model2DBundle(
            icon: computedImage,
            widthMeters: (model2D?.properties[.model2DWidth] as? Double) ?? 0,
            heightMeters: (model2D?.properties[.model2DHeight] as? Double) ?? 0)
    }

    var model2DState: Model2DState {
        if let hasIcon = (data[.model2D] as? UIImage) {
            if hasIcon != nil as UIImage? {
                return .visible
            } else {
                return .invisible
            }
        }
        return .invisible
    }

    var model2DPosition: CLLocationCoordinate2D? {
        if let point = model2D?.geometry.coordinates as? MPPoint {
            return point.coordinate
        }
        return nil
    }

    var model2DBearing: Double? {
        if let bearing = model2D?.properties[.model2dBearing] as? Double {
            return Double(bearing)
        }
        return nil
    }

    // for 2D Model
    var computedImage: UIImage? {
        switch model2DState {
        case .undefined, .invisible:
            return nil
        case .visible:
            if let image = data[.model2D] as? UIImage {
                return image
            } else {
                return nil
            }
        }
    }

    private var computedLabelImage: UIImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        let opacity = marker?.properties[.labelOpacity] as? Bool
        format.opaque = opacity ?? false

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping

        var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraphStyle]

        guard let string = (marker?.properties[.markerLabel] as? String),
            let fontSize = marker?.properties[.labelSize] as? Int,
            let fontName = marker?.properties[.labelFont] as? String,
            let fontColor = marker?.properties[.labelColor] as? String,
            let fontOpacity = marker?.properties[.labelOpacity] as? Double,
            let haloWidth = marker?.properties[.labelHaloWidth] as? Int,
            let haloColor = marker?.properties[.labelHaloColor] as? String,
            let haloBlur = marker?.properties[.labelHaloBlur] as? Int
        else { return nil }

        attrs[.font] = UIFont(name: fontName, size: CGFloat(fontSize))
        attrs[.foregroundColor] = UIColor(hex: fontColor)?.withAlphaComponent(CGFloat(fontOpacity))
        attrs[.strokeColor] = UIColor(hex: haloColor)?.withAlphaComponent(1)
        attrs[.strokeWidth] = -haloWidth
        let shadow = NSShadow()
        shadow.shadowBlurRadius = CGFloat(haloBlur)
        shadow.shadowOffset = .zero
        shadow.shadowColor = UIColor(hex: haloColor)?.withAlphaComponent(1)
        attrs[.shadow] = shadow

        let size = labelSplitAndSizing(string: string, width: Double(marker?.properties[.labelMaxWidth] as? UInt ?? UInt.max), att: attrs)
        guard size != .zero else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            string.draw(with: CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height)), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
        }
    }

    func labelSplitAndSizing(string: String, width: Double, att: [NSAttributedString.Key: Any]) -> CGSize {
        NSString(string: string).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: NSStringDrawingOptions.usesLineFragmentOrigin,
            attributes: att,
            context: nil
        ).size
    }
}

extension UIImage {
    fileprivate func withDebugBox(color _: UIColor = .red) -> UIImage {
        guard ViewState.debugDrawImageBorder == true else { return self }
        let size = CGSize(width: size.width, height: size.height)
        guard size != .zero else { return self }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let img = renderer.image { ctx in
            draw(at: CGPoint(x: 0, y: 0))
            let rectangle = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            UIColor.red.setStroke()
            ctx.stroke(rectangle)
        }
        return img
    }

    fileprivate func resizeImage(scaleSize: CGFloat) -> UIImage? {
        var size = size

        guard self.size.width <= scaleSize, self.size.height <= scaleSize else {
            return self
        }

        let scaleFactor = scaleSize / max(size.width, size.height)
        size.width *= scaleFactor
        size.height *= scaleFactor

        let rendererFormat = UIGraphicsImageRendererFormat.preferred()
        rendererFormat.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: rendererFormat)

        return renderer.image { _ in
            draw(in: CGRect(origin: CGPoint.zero, size: size))
        }
    }

    private func fillColor(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(context.format.bounds)
            draw(in: context.format.bounds, blendMode: .destinationIn, alpha: 1.0)
        }
    }
}

// MARK: Temporarily here

/// The different positions to place label of an MPLocation on the map.
@objc enum MPLabelPosition: Int, Codable {
    /// Will place labels on top.
    case top

    /// Will place labels on bottom.
    case bottom

    /// Will place labels on left.
    case left

    /// Will place labels on right.
    case right
}

// The "old", inefficient way
class LockedObject<T> {
    private var obj: T
    private let lock = NSLock()

    public required init(value: T) {
        self.obj = value
    }

    public var value: T {
        get {
            lock.withLock {
                return obj
            }
        }
        set {
            lock.withLock {
                obj = newValue
            }
        }
    }
}
