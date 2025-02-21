import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore
import UIKit

/**
  This enum defines which state changeing operations we have.
  There exists a state operation for each mutable characteristic of a view model's features (marker, polygon)
 */
enum StateOperation {
    case MARKER_VISIBLITY
    case MARKER_ICON
    case MARKER_POSITION
    case MARKER_ANCHOR
    case MARKER_CLICKABLE

    case POLYGON_VISIBILITY
    case POLYGON_FILL_COLOR
    case POLYGON_STROKE_COLOR
    case POLYGON_STROKE_WIDTH
    case POLYGON_GEOMETRY
    case POLYGON_CLICKABLE

    case FLOORPLAN_VISIBILITY
    case FLOORPLAN_STROKE_COLOR
    case FLOORPLAN_STROKE_WIDTH
    case FLOORPLAN_FILL_COLOR
    case FLOORPLAN_GEOMETRY

    case INFO_WINDOW

    case MODEL2D_VISIBILITY
    case MODEL2D_IMAGE
    case MODEL2D_POSITION
    case MODEL2D_BEARING
    case MODEL2D_CLICKABLE
}

enum MarkerState {
    case UNDEFINED
    case INVISIBLE
    case VISIBLE_ICON
    case VISIBLE_LABEL
    case VISIBLE_ICON_LABEL

    var isVisible: Bool {
        !(self == .INVISIBLE)
    }

    var isIconVisible: Bool {
        self == .VISIBLE_ICON || self == .VISIBLE_ICON_LABEL
    }

    var isLabelVisible: Bool {
        self == .VISIBLE_LABEL || self == .VISIBLE_ICON_LABEL
    }
}

enum Model2DState {
    case UNDEFINED
    case INVISIBLE
    case VISIBLE

    var isVisible: Bool {
        !(self == .INVISIBLE || self == .UNDEFINED)
    }
}

enum Constants {
    static let kMetersPerPixel = 0.014 // at 44°
}

enum PolygonState {
    case UNDEFINED
    case INVISIBLE
    case VISIBLE

    var isVisible: Bool {
        self == .VISIBLE
    }
}

/**
 This class is responsible for hosting map features (markers, polygons, etc.) and compare against a view model.
 If the "on-map" state of a feature differs from that of the view model, we compute a set of operations required to make the two states equal.
 */
actor ViewState {
    static let DEBUG_DRAW_IMAGE_BORDER = false

    private weak var map: GMSMapView!
    let id: String

    var lastTimeTag = CFAbsoluteTimeGetCurrent()

    // This is a dictionary because state operations are idempotent so we only ever need to execute one
    private nonisolated let deltaOperations = Locked<[StateOperation: (GMSMapView?) -> Void]>(value: [:])

    nonisolated let marker = Locked<GMSMarker?>(value: nil)
    private nonisolated let polygons = Locked<[GMSPolygon]>(value: [])
    private nonisolated let floorPlanPolygons = Locked<[GMSPolygon]>(value: [])
    private nonisolated let overlay2D = Locked<GMSGroundOverlay?>(value: nil)
    private nonisolated let InfoWindowAnchorPoint = Locked<CGPoint?>(value: nil)

    private var is2dModelsEnabled = false

    private var isFloorPlanEnabled = false

    nonisolated let shouldShowInfoWindowShadow = Locked<Bool>(value: false)
    var shouldShowInfoWindow: Bool = false {
        didSet {
            shouldShowInfoWindowShadow.value = shouldShowInfoWindow
            deltaOperations.value[.INFO_WINDOW] = { [weak self] map in
                if self?.shouldShowInfoWindowShadow.value ?? false, map?.selectedMarker != self?.marker.value {
                    map?.selectedMarker = self?.marker.value
                    if let anchor = self?.InfoWindowAnchorPoint.value {
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

    // Area of the underlying MapsIndoors Geometry (not necessarily related to the rendered geometry)
    nonisolated let poiArea = Locked<Double>(value: 0.0)

    private var imageBundle: IconLabelBundle?
    private var model2dBundle: Model2DBundle?

    // Enables forced rendering (for selection & highlight) - collision logic checks this flag
    nonisolated let forceRender = Locked<Bool>(value: false)

    nonisolated let infoWindowText = Locked<String?>(value: nil)

    // MARK: Marker
    
    func setMarkerState(state: MarkerState) {
        self.markerState = state
    }

    nonisolated let markerStateShadow = Locked<MarkerState>(value: .UNDEFINED)
    var markerState: MarkerState = .UNDEFINED {
        didSet {
            markerStateShadow.value = markerState
            switch markerState {
            case .VISIBLE_ICON_LABEL:
                markerIcon = imageBundle?.both?.withDebugBox()
            case .VISIBLE_ICON:
                markerIcon = imageBundle?.icon?.withDebugBox()
            case .VISIBLE_LABEL:
                markerIcon = imageBundle?.label?.withDebugBox()
            case .UNDEFINED:
                fallthrough
            case .INVISIBLE:
                break
            }

            deltaOperations.value[.MARKER_VISIBLITY] = { [weak self] map in
                switch self?.markerStateShadow.value {
                case .VISIBLE_ICON_LABEL:
                    fallthrough
                case .VISIBLE_ICON:
                    fallthrough
                case .VISIBLE_LABEL:
                    if self?.marker.value?.icon == nil {
                        self?.marker.value?.icon = UIImage()
                    }
                    self?.marker.value?.map = map
                case .UNDEFINED:
                    fallthrough
                case .INVISIBLE:
                    self?.marker.value?.map = nil
                case .none:
                    return
                }
            }
        }
    }

    nonisolated let markerAnchorShadow = Locked<CGPoint>(value: CGPoint(x: 0.5, y: 0.5))
    var markerAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5) {
        didSet {
            markerAnchorShadow.value = markerAnchor
            deltaOperations.value[.MARKER_ANCHOR] = { [weak self] _ in
                guard self?.marker.value?.groundAnchor != self?.markerAnchorShadow.value else { return }
                self?.marker.value?.groundAnchor = self?.markerAnchorShadow.value ?? CGPoint(x: 0.5, y: 0.5)
            }
        }
    }

    nonisolated let markerPositionShadow = Locked<CLLocationCoordinate2D?>(value: nil)
    var markerPosition: CLLocationCoordinate2D? {
        didSet {
            markerPositionShadow.value = markerPosition
            deltaOperations.value[.MARKER_POSITION] = { [weak self] _ in
                guard let markerPosition = self?.markerPositionShadow.value, self?.marker.value?.position != markerPosition else { return }
                self?.marker.value?.position = markerPosition
            }
        }
    }

    nonisolated let markerIconShadow = Locked<UIImage?>(value: nil)
    var markerIcon: UIImage? {
        didSet {
            markerIconShadow.value = markerIcon
            deltaOperations.value[.MARKER_ICON] = { [weak self] _ in
                guard self?.marker.value?.icon != self?.markerIconShadow.value, self?.markerIconShadow.value != nil else { return }
                self?.marker.value?.icon = self?.markerIconShadow.value
            }
        }
    }

    nonisolated let markerClickableShadow = Locked<Bool>(value: false)
    var markerClickable: Bool = false {
        didSet {
            markerClickableShadow.value = markerClickable
            deltaOperations.value[.MARKER_CLICKABLE] = { [weak self] _ in
                self?.marker.value?.isTappable = self?.markerClickableShadow.value ?? false
            }
        }
    }

    // MARK: floorPlan
    nonisolated let floorPlanStateShadow = Locked<PolygonState>(value: .UNDEFINED)
    var floorPlanState: PolygonState = .UNDEFINED {
        didSet {
            floorPlanStateShadow.value = floorPlanState
            deltaOperations.value[.FLOORPLAN_VISIBILITY] = { [weak self] map in
                switch self?.floorPlanStateShadow.value {
                case .VISIBLE:
                    for wall in self?.floorPlanPolygons.value ?? [] {
                        wall.map = map
                    }
                case .UNDEFINED:
                    fallthrough
                case .INVISIBLE:
                    for wall in self?.floorPlanPolygons.value ?? [] {
                        wall.map = nil
                    }
                case .none:
                    return
                }
            }
        }
    }

    nonisolated let floorPlanStrokeColorShadow = Locked<UIColor?>(value: nil)
    var floorPlanStrokeColor: UIColor? {
        didSet {
            floorPlanStrokeColorShadow.value = floorPlanStrokeColor
            deltaOperations.value[.FLOORPLAN_STROKE_COLOR] = { [weak self] _ in
                for floorPlan in self?.floorPlanPolygons.value ?? [] {
                    floorPlan.strokeColor = self?.floorPlanStrokeColorShadow.value
                }
            }
        }
    }

    nonisolated let floorPlanStrokeWidthShadow = Locked<Double?>(value: nil)
    var floorPlanStrokeWidth: Double? {
        didSet {
            floorPlanStrokeWidthShadow.value = floorPlanStrokeWidth
            deltaOperations.value[.FLOORPLAN_STROKE_WIDTH] = { [weak self] _ in
                for floorPlan in self?.floorPlanPolygons.value ?? [] {
                    floorPlan.strokeWidth = CGFloat(self?.floorPlanStrokeWidthShadow.value ?? 0.0)
                }
            }
        }
    }

    nonisolated let floorPlanFillColorShadow = Locked<UIColor?>(value: nil)
    var floorPlanFillColor: UIColor? {
        didSet {
            floorPlanFillColorShadow.value = floorPlanFillColor
            deltaOperations.value[.FLOORPLAN_FILL_COLOR] = { [weak self] _ in
                for floorPlan in self?.floorPlanPolygons.value ?? [] {
                    floorPlan.fillColor = self?.floorPlanFillColorShadow.value
                }
            }
        }
    }

    nonisolated let floorPlanGeometriesShadow = Locked<[GMSPath]>(value: [])
    var floorPlanGeometries: [GMSPath]? {
        didSet {
            floorPlanGeometriesShadow.value = floorPlanGeometries ?? []
            deltaOperations.value[.FLOORPLAN_GEOMETRY] = { [weak self] map in
                let upper = Double(MapOverlayZIndex.endFloorPlanRange.rawValue)
                let lower = Double(MapOverlayZIndex.startFloorPlanRange.rawValue)
                let zindex = (abs(upper - (self?.poiArea.value ?? 0.0)).truncatingRemainder(dividingBy: lower) + lower) - 1 // -1 to ensure it is rendered below regular polygon geometry

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

    // MARK: Polygon
    nonisolated let polygonStateShadow = Locked<PolygonState>(value: .UNDEFINED)
    var polygonState: PolygonState = .UNDEFINED {
        didSet {
            polygonStateShadow.value = polygonState
            deltaOperations.value[.POLYGON_VISIBILITY] = { [weak self] map in
                for polygon in self?.polygons.value ?? [] {
                    polygon.userData = self?.id
                }
                switch self?.polygonStateShadow.value {
                case .VISIBLE:
                    for polygon in self?.polygons.value ?? [] {
                        polygon.map = map
                    }
                case .UNDEFINED:
                    fallthrough
                case .INVISIBLE:
                    for polygon in self?.polygons.value ?? [] {
                        polygon.map = nil
                    }
                case .none:
                    return
                }
            }
        }
    }

    nonisolated let polygonFillColorShadow = Locked<UIColor?>(value: nil)
    var polygonFillColor: UIColor? {
        didSet {
            polygonFillColorShadow.value = polygonFillColor
            deltaOperations.value[.POLYGON_FILL_COLOR] = { [weak self] _ in
                for polygon in self?.polygons.value ?? [] {
                    polygon.fillColor = self?.polygonFillColorShadow.value
                }
            }
        }
    }

    nonisolated let polygonStrokeColorShadow = Locked<UIColor?>(value: nil)
    var polygonStrokeColor: UIColor? {
        didSet {
            polygonStrokeColorShadow.value = polygonStrokeColor
            deltaOperations.value[.POLYGON_STROKE_COLOR] = { [weak self] _ in
                for polygon in self?.polygons.value ?? [] {
                    polygon.strokeColor = self?.polygonStrokeColorShadow.value
                }
            }
        }
    }

    nonisolated let polygonStrokeWidthShadow = Locked<Double?>(value: nil)
    var polygonStrokeWidth: Double? {
        didSet {
            polygonStrokeWidthShadow.value = polygonStrokeWidth
            deltaOperations.value[.POLYGON_STROKE_WIDTH] = { [weak self] _ in
                for polygon in self?.polygons.value ?? [] {
                    polygon.strokeWidth = CGFloat(self?.polygonStrokeWidthShadow.value ?? 0.0)
                }
            }
        }
    }

    nonisolated let polygonGeometriesShadow = Locked<[GMSPath]>(value: [])
    var polygonGeometries: [GMSPath]? {
        didSet {
            polygonGeometriesShadow.value = polygonGeometries ?? []
            deltaOperations.value[.POLYGON_GEOMETRY] = { [weak self] map in
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

    nonisolated let polygonClickableShadow = Locked<Bool>(value: false)
    var polygonClickable: Bool = false {
        didSet {
            polygonClickableShadow.value = polygonClickable
            deltaOperations.value[.POLYGON_CLICKABLE] = { [weak self] _ in
                for polygon in self?.polygons.value ?? [] {
                    polygon.isTappable = self?.polygonClickableShadow.value ?? false
                }
            }
        }
    }

    // MARK: 2D Model

    private nonisolated let model2DStateShadow = Locked<Model2DState>(value: .UNDEFINED)
    private var model2DState: Model2DState = .UNDEFINED {
        didSet {
            model2DStateShadow.value = model2DState
            if oldValue != model2DState {
                deltaOperations.value[.MODEL2D_VISIBILITY] = { [weak self] map in
                    switch self?.model2DStateShadow.value {
                    case .VISIBLE:
                        self?.overlay2D.value?.map = map
                    case .UNDEFINED:
                        fallthrough
                    case .INVISIBLE:
                        self?.overlay2D.value?.map = nil
                    case .none:
                        return
                    }
                }
            }
        }
    }

    private nonisolated let model2DPositionShadow = Locked<CLLocationCoordinate2D?>(value: nil)
    private var model2DPosition: CLLocationCoordinate2D? {
        didSet {
            model2DPositionShadow.value = model2DPosition
            deltaOperations.value[.MODEL2D_POSITION] = { [weak self] _ in
                guard let model2DPosition = self?.model2DPositionShadow.value, self?.overlay2D.value?.position != model2DPosition else { return }
                self?.overlay2D.value?.position = model2DPosition
            }
        }
    }

    private nonisolated let model2DImageShadow = Locked<UIImage?>(value: nil)
    private var model2DImage: UIImage? {
        didSet {
            model2DImageShadow.value = model2DImage
            deltaOperations.value[.MODEL2D_IMAGE] = { [weak self] _ in
                
                var bounds: GMSCoordinateBounds? = nil
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

    private nonisolated let model2DBearingShadow = Locked<Double?>(value: nil)
    private var model2DBearing: Double? {
        didSet {
            model2DBearingShadow.value = model2DBearing
            if oldValue != model2DBearing {
                deltaOperations.value[.MODEL2D_BEARING] = { [weak self] _ in
                    self?.overlay2D.value?.bearing = self?.model2DBearingShadow.value ?? 0.0
                }
            }
        }
    }
    
    private nonisolated let model2DClickableShadow = Locked<Bool>(value: false)
    var model2DClickable: Bool = false {
        didSet {
            model2DClickableShadow.value = model2DClickable
            deltaOperations.value[.MODEL2D_CLICKABLE] = { [weak self] _ in
                self?.overlay2D.value?.isTappable = self?.model2DClickableShadow.value ?? false
            }
        }
    }

    var iconSize = CGSize.zero
    var labelSize = CGSize.zero

    @MainActor
    var bounds: CGRect? {
        get async {
            guard await markerState.isVisible, await markerPosition != nil, await markerIcon != nil else { return nil }
            var rect: CGRect?
            if let markerPos = await markerPosition {
                let p = await map.projection.point(for: markerPos)
                if let size = await imageBundle?.getSize(state: markerState) {
                    let x = await p.x - (size.width * markerAnchor.x)
                    let y = await p.y - (size.height * markerAnchor.y)
                    rect = CGRect(x: x, y: y, width: size.width, height: size.height)
                }
            }
            return rect
        }
    }

    private nonisolated let model2DWidthMeters = Locked<Double>(value: 0.0)
    private nonisolated let model2DHeightMeters = Locked<Double>(value: 0.0)

    @MainActor
    init(viewModel: any MPViewModel, map: GMSMapView, is2dModelEnabled: Bool, isFloorPlanEnabled: Bool) async {
        id = viewModel.id
        self.map = map

        await marker.value = GMSMarker(position: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        await marker.value?.zIndex = Int32(MapOverlayZIndex.startMarkerOverlay.rawValue)
        await overlay2D.value = GMSGroundOverlay(bounds: nil, icon: nil)
        await polygons.value = [GMSPolygon]()

        self.is2dModelsEnabled = is2dModelEnabled
        self.isFloorPlanEnabled = isFloorPlanEnabled

        await marker.value?.userData = self.id
        await overlay2D.value?.userData = self.id
    }

    func calculateMarkerAnchor(markerSize: Double, iconSize: Double, anchor: Double) -> Double {
        (iconSize * anchor) / markerSize
    }

    /**
     Computes the set of state operations required to have the view state's properties reflect those in the view model.
     This is done by assigning model values to the view state's corresponding property. Upon each property assignment, it check
     whether the value has changed - and a function is created to accommodate this change property and reflect the changes on corresponding map feature.
     */
    func computeDelta(newModel: any MPViewModel) {
        lastTimeTag = CFAbsoluteTimeGetCurrent()
        deltaOperations.value.removeAll()
        infoWindowText.value = newModel.marker?.properties[.markerLabelInfoWindow] as? String
        markerState = newModel.markerState
        if markerState.isVisible || markerState == .UNDEFINED {
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

                if let size = bundle.getSize(state: .VISIBLE_ICON_LABEL) {
                    let anchorX = calculateMarkerAnchor(markerSize: size.width, iconSize: bundle.iconSize.width, anchor: 0.5)

                    if markerState.isIconVisible, markerState.isLabelVisible {
                        markerAnchor = CGPoint(x: anchorX, y: 0.5)
                        InfoWindowAnchorPoint.value = CGPoint(x: anchorX, y: 0)
                        DispatchQueue.main.async {
                            if newModel.marker?.properties[.isCollidable] as? Bool == false {
                                if self.markerState.isLabelVisible || self.markerState.isIconVisible {
                                    self.InfoWindowAnchorPoint.value = CGPoint(x: anchorX, y: 0)
                                }
                            }
                        }
                    } else if markerState.isIconVisible {
                        markerAnchor = CGPoint(x: 0.5, y: 0.5)
                    }

                    if markerState.isIconVisible, markerState.isLabelVisible {
                        DispatchQueue.main.async {
                            self.marker.value?.infoWindowAnchor = CGPoint(x: anchorX, y: 0)
                        }

                        if let iconPlacement = newModel.marker?.properties[.markerIconPlacement] as? String,
                           let labelPlacement = newModel.marker?.properties[.labelAnchor] as? String {
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

        shouldShowInfoWindow = newModel.showInfoWindow

        polygonState = newModel.polygonState
        if polygonState.isVisible || polygonState == .UNDEFINED {
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
            if floorPlanState.isVisible || floorPlanState == .UNDEFINED {
                floorPlanStrokeColor = newModel.floorPlanStrokeColor
                floorPlanStrokeWidth = newModel.floorPlanStrokeWidth
                floorPlanFillColor = newModel.floorPlanFillColor
                floorPlanGeometries = newModel.floorPlanGeometries
            }
        }

        if is2dModelsEnabled {
            model2DState = newModel.model2DState
            if model2DState.isVisible || model2DState == .UNDEFINED {
                if let bundle = newModel.model2DBundle {
                    if let image = bundle.icon {
                        let zoom = Int(map.camera.zoom)
                        let scaleFactor = switch zoom {
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

    private func ratio(a: Double, b: Double) -> Double {
        min(a, b) / max(a, b)
    }

    /**
     Executes the set of state operations, computed to "catch up" with the state of the latest view model
     */
    @MainActor
    func applyDelta() async {
        let renderOperationsInOrder: [StateOperation] = [
            .MARKER_ANCHOR,
            .MARKER_ICON,
            .MARKER_VISIBLITY,
            .MARKER_POSITION,
            .MARKER_CLICKABLE,
            .INFO_WINDOW,
            .POLYGON_STROKE_WIDTH,
            .POLYGON_FILL_COLOR,
            .POLYGON_STROKE_COLOR,
            .POLYGON_VISIBILITY,
            .POLYGON_GEOMETRY,
            .POLYGON_CLICKABLE,
            .FLOORPLAN_STROKE_WIDTH,
            .FLOORPLAN_STROKE_COLOR,
            .FLOORPLAN_VISIBILITY,
            .FLOORPLAN_GEOMETRY,
            .MODEL2D_IMAGE,
            .MODEL2D_BEARING,
            .MODEL2D_VISIBILITY,
            .MODEL2D_POSITION,
            .MODEL2D_CLICKABLE
        ]
        
        weak var weakMap = await self.map
        
        _ = await withTaskGroup(of: Void.self) { group in
            for op in deltaOperations.value.values {
                _ = group.addTaskUnlessCancelled(priority: .high) {
                    Task { @MainActor in
                        op(weakMap)
                    }
                }
            }
        }
        /*
         for operationType in renderOperationsInOrder {
             if let operation = deltaOperations[operationType] {
                 operation(self.map)
                 deltaOperations.remove(key: operationType)
             }
         }
          */
    }

    /**
     Removes all map features from the mapview
      */
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
        case .INVISIBLE:
            nil
        case .VISIBLE_ICON:
            iconSize
        case .VISIBLE_LABEL:
            labelSize
        case .VISIBLE_ICON_LABEL:
            both?.size
        default:
            nil
        }
    }

    private func compile(icon: UIImage?, label: UIImage?, position: MPLabelPosition) -> UIImage? {
        let respectDistance = CGFloat(3)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false // true = no alpha channel, for debugging

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

/**
 Convenience extensions for view models, useful in the ViewState class' logic
 */
extension MPViewModel {
    var markerState: MarkerState {
        if let feature = marker {
            let hasLabel = feature.properties[.markerLabel] != nil
            let hasIcon = (data[.icon] as? UIImage) != nil
            if hasIcon, hasLabel {
                return .VISIBLE_ICON_LABEL
            }
            if hasIcon {
                return .VISIBLE_ICON
            }
            if hasLabel {
                return .VISIBLE_LABEL
            }
        }
        return .INVISIBLE
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
                return .VISIBLE
            } else {
                return .INVISIBLE
            }
        }
        return .INVISIBLE
    }

    var polygonGeometries: [GMSPath] {
        var geometries = [GMSPath]()

        if polygon?.geometry.type == .Polygon {
            for polygon in polygon?.geometry.coordinates as! [[MPPoint]] {
                let path = GMSMutablePath()
                for pathPoint in polygon {
                    path.add(pathPoint.coordinate)
                }
                geometries.append(path)
            }
        }

        if polygon?.geometry.type == .MultiPolygon {
            for polygons in polygon?.geometry.coordinates as! [MPPolygonGeometry] {
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
            return .VISIBLE
        } else {
            return .INVISIBLE
        }
    }

    var floorPlanGeometries: [GMSPath] {
        var geometries = [GMSPath]()

        if floorPlanExtrusion?.geometry.type == .Polygon {
            for polygon in floorPlanExtrusion?.geometry.coordinates as! [[MPPoint]] {
                let path = GMSMutablePath()
                for pathPoint in polygon {
                    path.add(pathPoint.coordinate)
                }
                geometries.append(path)
            }
        }

        if floorPlanExtrusion?.geometry.type == .MultiPolygon {
            for polygons in floorPlanExtrusion?.geometry.coordinates as! [MPPolygonGeometry] {
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
            labelPosition = switch position {
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
        Model2DBundle(icon: computedImage,
                      widthMeters: (model2D?.properties[.model2DWidth] as? Double) ?? 0,
                      heightMeters: (model2D?.properties[.model2DHeight] as? Double) ?? 0)
    }

    var model2DState: Model2DState {
        if let hasIcon = (data[.model2D] as? UIImage) {
            if hasIcon != nil as UIImage? {
                return .VISIBLE
            } else {
                return .INVISIBLE
            }
        }
        return .INVISIBLE
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
        case .UNDEFINED:
            fallthrough
        case .INVISIBLE:
            return nil
        case .VISIBLE:
            if let image = data[.model2D] as? UIImage {
                return image
            } else { return nil }
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
              let haloBlur = marker?.properties[.labelHaloBlur] as? Int else { return nil }

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
        NSString(string: string).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                              options: NSStringDrawingOptions.usesLineFragmentOrigin,
                                              attributes: att,
                                              context: nil).size
    }
}

private extension UIImage {
    func withDebugBox(color _: UIColor = .red) -> UIImage {
        guard ViewState.DEBUG_DRAW_IMAGE_BORDER == true else { return self }
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

    func resizeImage(scaleSize: CGFloat) -> UIImage? {
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
