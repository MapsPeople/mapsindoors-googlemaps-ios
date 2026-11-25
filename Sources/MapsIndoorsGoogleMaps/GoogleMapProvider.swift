import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

// SAFETY: (SPEX-1975) GoogleMapProvider wraps main-thread-only Google Maps UI and is
// only ever accessed on the main actor, so it is safe to share by that convention. (MPMapProvider
// is Sendable; the type-system proof is deferred with the wider provider-isolation work.)
public class GoogleMapProvider: MPMapProvider, @unchecked Sendable {
    public let model2DResolutionLimit = 200
    public let providerName = "google"

    // Unused on Google Maps
    public var enableNativeMapBuildings: Bool = false

    public var routingService: MPExternalDirectionsService {
        GMDirectionsService(apiKey: googleApiKey! as String)
    }

    public var distanceMatrixService: MPExternalDistanceMatrixService {
        GMDistanceMatrixService(apiKey: googleApiKey! as String)
    }

    public func invalidateRenderCache() {
        // nothing
    }

    public var customInfoWindow: MPCustomInfoWindow?

    public func reloadTilesForFloorChange() {}

    var renderer: Renderer?
    private var _routeRenderer: GMRouteRenderer?
    private var tileProvider: GMTileProvider?

    /// Tracks the in-flight render so a new `setViewModels` can cancel and
    /// await its predecessor before starting. Main-actor isolated so the
    /// cancel/await/replace sequence is itself race-free.
    @MainActor private var renderTask: Task<Void, Never>?

    public var collisionHandling: MPCollisionHandling = .allowOverLap

    public var cameraOperator: MPCameraOperator {
        GMCameraOperator(gmsView: mapView, provider: self)
    }

    public var routeRenderer: MPRouteRenderer { _routeRenderer! }

    @MainActor
    public func setTileProvider(tileProvider: MPTileProvider) async {
        self.tileProvider?.map = nil
        self.tileProvider = GMTileProvider(provider: tileProvider)
        self.tileProvider?.map = mapView
    }

    // The view delegate is main-actor state behind a non-isolated public surface; see `mpOnMainSync`.
    public var delegate: MPMapProviderDelegate? {
        set {
            mpOnMainSync("GoogleMapProvider.delegate") { mapViewDelegate?.mapsIndoorsDelegate = newValue }
        }
        get {
            mpOnMainSync("GoogleMapProvider.delegate") { mapViewDelegate?.mapsIndoorsDelegate }
        }
    }

    private weak var mapView: GMSMapView?

    private var googleApiKey: String?

    private var mapViewDelegate: GoogleMapViewDelegate?

    public var positionPresenter: MPPositionPresenter

    public var cameraPosition: MPCameraPosition

    public init(mapView: GMSMapView, googleApiKey: String? = nil) {
        self.mapView = mapView
        renderer = Renderer(map: self.mapView)
        _routeRenderer = GMRouteRenderer(map: self.mapView)

        self.googleApiKey = googleApiKey

        cameraPosition = GMCameraPosition(cameraPosition: GMSMutableCameraPosition())

        // The map view is main-actor state and the presenter creates Google Maps overlays; the initialiser is
        // reached through `MPMapConfig(gmsMapView:googleApiKey:)` on the main thread, so this is a same-thread
        // fast path in practice and a logged hop otherwise.
        positionPresenter = mpOnMainSync("GoogleMapProvider.init") { GMPositionPresenter(map: mapView) }

        mapViewDelegate = mpOnMainSync("GoogleMapProvider.init") { [self] in
            let mapViewDelegate = GoogleMapViewDelegate(googleMapProvider: self)
            mapView.isBuildingsEnabled = false
            mapView.isIndoorEnabled = false
            // The engine's own range, not a hard-coded one: below `kGMSMinZoomLevel` is no zoom Google draws.
            mapView.setMinZoom(kGMSMinZoomLevel, maxZoom: kGMSMaxZoomLevel)
            if let originalDelegate = mapView.delegate {
                mapViewDelegate.originalMapViewDelegate = originalDelegate
            }
            mapView.delegate = mapViewDelegate
            return mapViewDelegate
        }

        // Before the map has drawn anything. This is what hides Google's own POI icons, and it is a
        // bundled JSON file, so there is nothing to wait for. Left to its old trigger
        // (`mapViewDidFinishTileRendering`) it lands only once every tile and label has rendered —
        // ~12 s on a cold start — blanking a map the user is already looking at.
        if let mapView = self.mapView {
            // Same hop as the two calls above, for the same reason: the delegate is `@MainActor` and this
            // initialiser is not, though it is reached on the main thread through
            // `MPMapConfig(gmsMapView:googleApiKey:)`.
            mpOnMainSync("GoogleMapProvider.init") { mapViewDelegate?.applyMapsPeopleStylingIfNeeded(to: mapView) }
        }

        // Register the no-op base-map cache provider. `MapBoxProvider` registers its real
        // implementation on init; without a matching registration here, switching from the
        // Mapbox provider back to Google would leave the stale Mapbox provider registered,
        // and base-map caching would wrongly run against the Mapbox TileStore. The active
        // provider owns the global registration, so the no-op makes Google correctly report
        // `baseMapCachingNotSupported`.
        MPMapsIndoors.baseMapCacheProvider = GMBaseMapCacheProvider()
    }

    @MainActor
    public func setViewModels(models: [any MPViewModel], forceClear: Bool) async {
        await configureMapsIndoorsModuleLicensing()

        // Serialize renders so only one render flow is ever alive, even under
        // multiple concurrent callers. `Renderer.setViewModels` runs on a
        // reentrant actor that suspends at every stage, so two overlapping
        // renders would interleave across the cooperative pool holding the same
        // `any MPViewModel` existentials — the GoogleMaps analogue of the
        // cross-render retain/release crash fixed for Mapbox in SPEX-1713.
        //
        // The predecessor is captured and the replacement published with no
        // `await` between the read of `renderTask` and its reassignment, so a
        // second caller arriving on the main actor sees *this* task as its
        // predecessor and chains behind it instead of all parking on the same
        // older task (which would let their renderer calls run concurrently once
        // that shared predecessor completed). Awaiting the predecessor happens
        // *inside* the new task, so the renderer call starts only after the
        // prior render has fully unwound and released its existential captures.
        let collision = collisionHandling
        let previous = renderTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.renderer?.setViewModels(models: models, collision: collision, forceClear: forceClear)
            } catch {
                // do nothing — includes CancellationError when superseded
            }
        }
        renderTask = task
        await task.value
    }

    public var view: UIView? {
        mapView
    }

    // `mapView` is main-actor state behind a non-isolated public surface; see `mpOnMainSync`.
    public var mpAccessibilityElementsHidden: Bool {
        get {
            mpOnMainSync("GoogleMapProvider.mpAccessibilityElementsHidden") { mapView?.accessibilityElementsHidden ?? true }
        }
        set {
            mpOnMainSync("GoogleMapProvider.mpAccessibilityElementsHidden") { mapView?.accessibilityElementsHidden = newValue }
        }
    }

    public var padding: UIEdgeInsets {
        get {
            mpOnMainSync("GoogleMapProvider.padding") { mapView?.padding ?? UIEdgeInsets.zero }
        }
        set {
            mpOnMainSync("GoogleMapProvider.padding") { mapView?.padding = newValue }
        }
    }

    /// `GMSMapView.padding` is consulted by every Google Maps camera
    /// operation automatically — `map.animate(to:)`,
    /// `GMSCameraUpdate.fit(_:)`, `map.camera(for:insets:)`, etc. —
    /// so the engine itself handles ``MPMapControl/mapPadding`` for
    /// every camera move. Callers that pre-combine `mapPadding` into
    /// a per-operation padding value must omit it on this provider
    /// to avoid double-application.
    public var appliesPaddingGlobally: Bool { true }

    /// What the map view had before ``cameraLimits`` was first applied, restored when it is cleared.
    /// Captured once per stretch of active limits, so re-assigning limits keeps the original baseline.
    ///
    /// The whole snapshot is written back, so a change the app makes to one of these properties while
    /// limits are active does not survive clearing them. The zoom range is not part of it: it has its
    /// own single writer, ``applyZoomRange()``, since the licensed cap narrows it with or without limits.
    private struct CameraLimitsBaseline {
        let cameraTargetBounds: GMSCoordinateBounds?
        let rotateGestures: Bool
        let tiltGestures: Bool
        let compassButton: Bool

        @MainActor init(capturing mapView: GMSMapView) {
            cameraTargetBounds = mapView.cameraTargetBounds
            rotateGestures = mapView.settings.rotateGestures
            tiltGestures = mapView.settings.tiltGestures
            compassButton = mapView.settings.compassButton
        }

        @MainActor func restore(on mapView: GMSMapView) {
            mapView.cameraTargetBounds = cameraTargetBounds
            mapView.settings.rotateGestures = rotateGestures
            mapView.settings.tiltGestures = tiltGestures
            mapView.settings.compassButton = compassButton
        }
    }

    private var cameraLimitsBaseline: CameraLimitsBaseline?

    /// The map view's zoom range before the SDK first narrowed it. Kept for the lifetime of the provider,
    /// since both the licensed zoom cap and ``cameraLimits`` are expressed relative to it.
    private var zoomBaseline: (min: Float, max: Float)?

    /// The highest zoom the solution's modules license. `nil` until a solution has been loaded.
    private var licensedMaxZoom: Float?

    /// Test injection point for the solution's module list. Tests have no loaded solution, so without
    /// this the licensed cap cannot be asserted at all. Mirrors `MapBoxProvider.solutionModulesOverride`.
    @MainActor internal var solutionModulesOverride: [String]?

    public var cameraLimits: MPCameraLimits? {
        // Set from `MPMapControlInternal` on the main actor; the setter's signature carries no
        // isolation, so assert before touching the map view.
        didSet { MainActor.assumeIsolated { applyCameraLimits() } }
    }

    /// Google Maps constrains gestures only: `cameraTargetBounds` does not hold a camera move made in code,
    /// and a fixed bearing or tilt is held by disabling the gesture that would change it. So every camera
    /// move the SDK makes goes through ``cameraWithinLimits(_:)`` first, and ``reapplyCameraLimits()``
    /// puts the camera back once any other move has ended. Google's zoom scale is the MapsIndoors zoom
    /// scale.
    @MainActor
    private func applyCameraLimits() {
        guard let mapView else { return }

        // New limits are a new ask, even from a camera an earlier correction gave up on.
        lastCorrection = nil
        // The route camera fits for a fixed bearing and tilt rather than turning to them afterwards.
        _routeRenderer?.cameraLimits = cameraLimits
        licensedMaxZoom = Self.licensedMaxZoom(modules: solutionModulesOverride ?? MPMapsIndoors.shared.solution?.modules)
        applyZoomRange()

        guard let limits = cameraLimits else {
            cameraLimitsBaseline?.restore(on: mapView)
            cameraLimitsBaseline = nil
            return
        }

        let baseline = cameraLimitsBaseline ?? CameraLimitsBaseline(capturing: mapView)
        cameraLimitsBaseline = baseline

        mapView.cameraTargetBounds = limits.orderedBounds.map { GMSCoordinateBounds(coordinate: $0.southWest, coordinate: $0.northEast) } ?? baseline.cameraTargetBounds

        let holdsBearing = limits.fixedBearingDegrees != nil
        mapView.settings.rotateGestures = holdsBearing ? false : baseline.rotateGestures
        mapView.settings.tiltGestures = limits.holdsFixedTilt ? false : baseline.tiltGestures
        // The compass button turns the map back to north on a tap, which rotation being disabled does
        // not prevent, so it has to go while a bearing is held.
        mapView.settings.compassButton = holdsBearing ? false : baseline.compassButton

        reapplyCameraLimits()
    }

    /// The single writer of the map view's zoom range, so the licensed cap and ``cameraLimits`` cannot
    /// overwrite one another. The licensed cap is the ceiling for the user's zoom, and the limits only
    /// narrow the range inside it.
    @MainActor
    private func applyZoomRange() {
        guard let mapView else { return }

        let baseline = zoomBaseline ?? (mapView.minZoom, mapView.maxZoom)
        zoomBaseline = baseline

        let ceiling = Swift.min(baseline.max, licensedMaxZoom ?? baseline.max)
        let zoom = cameraLimits?.zoomRange(engineMin: Double(baseline.min), engineMax: Double(ceiling)) ?? (min: Double(baseline.min), max: Double(ceiling))
        mapView.setMinZoom(Float(zoom.min), maxZoom: Float(zoom.max))
    }

    /// Re-reads the licensed cap from the solution's modules, which can arrive after the map does, and
    /// re-applies the zoom range only when the cap changed.
    @MainActor
    func applyLicensedZoomCap() {
        let cap = Self.licensedMaxZoom(modules: solutionModulesOverride ?? MPMapsIndoors.shared.solution?.modules)
        guard cap != licensedMaxZoom else { return }
        licensedMaxZoom = cap
        applyZoomRange()
    }

    /// The cap every provider applies, see ``MPLicensedZoom``. Google's zoom scale is the MapsIndoors
    /// scale, so no conversion is needed.
    private static func licensedMaxZoom(modules: [String]?) -> Float? {
        MPLicensedZoom.maxZoom(modules: modules).map(Float.init)
    }

    /// `camera` with every limit applied: its zoom inside the map view's zoom range, its target inside
    /// ``MPCameraLimits/bounds``, and its bearing and tilt at the fixed ones. The camera operator runs
    /// each move the SDK makes through this, so the camera never leaves the limits on the way.
    @MainActor
    func cameraWithinLimits(_ camera: GMSCameraPosition) -> GMSCameraPosition {
        guard let limits = cameraLimits else { return camera }

        // The map view's range already holds the zoom limits and the licensed cap.
        let zoom = mapView.map { Swift.min(Swift.max(camera.zoom, $0.minZoom), $0.maxZoom) } ?? camera.zoom
        return GMSCameraPosition(
            target: limits.clampedTarget(camera.target),
            zoom: zoom,
            bearing: limits.fixedBearingDegrees ?? camera.bearing,
            viewingAngle: limits.fixedTiltDegrees(maxTilt: Self.maxViewingAngle) ?? camera.viewingAngle)
    }

    /// Puts the camera back inside the limits after something moved it out of them.
    ///
    /// The SDK's own moves are fitted for the fixed bearing and tilt and kept inside on the way (see
    /// ``fitUpdate(for:)`` and `GMRouteRenderer`), but the engine decides where a fit to bounds lands
    /// without one, and a move the app makes on the `GMSMapView` itself bypasses the SDK altogether.
    /// Correcting once the camera is idle covers every such move at one point, at the cost of the camera
    /// visibly moving back after one that left the limits.
    ///
    /// The engine may not be able to land where the correction asks: Google lowers the steepest tilt it
    /// shows as the camera zooms out, so a fixed tilt of 30 can end at less. The correction's own move ends
    /// in another idle, so a correction is not asked for again from the camera it was last asked from,
    /// until the camera is next found inside the limits. That bounds it to one retry after the engine fell
    /// short, instead of a correction on every idle.
    @MainActor
    func reapplyCameraLimits() {
        guard let mapView, let limits = cameraLimits else { return }

        let camera = mapView.camera
        let kept = cameraWithinLimits(camera)
        let bearing = limits.bearingCorrection(from: camera.bearing)
        let tilt = limits.tiltCorrection(from: camera.viewingAngle, maxTilt: Self.maxViewingAngle)
        guard !Self.isSame(kept.target, camera.target) || abs(kept.zoom - camera.zoom) > Self.zoomTolerance || bearing != nil || tilt != nil else {
            // Inside the limits: whatever was asked last is done with, so a later move back to that same
            // camera is a new move to correct, not the engine falling short again.
            lastCorrection = nil
            return
        }

        let correction = GMSCameraPosition(
            target: kept.target,
            zoom: kept.zoom,
            bearing: bearing ?? camera.bearing,
            viewingAngle: tilt ?? camera.viewingAngle)
        if let last = lastCorrection, Self.isSame(last.from, camera), Self.isSame(last.to, correction) { return }

        lastCorrection = (from: camera, to: correction)
        // A camera move like any other, so it follows the motion gate (host flag or Reduce Motion, see
        // `MPCameraMotion`) the way `GMCameraOperator` does (SPEX-2060).
        let driver: any GMCameraDriving = correctionDriverOverride ?? mapView
        let update = GMSCameraUpdate.setCamera(correction)
        if MPCameraMotion.shouldAnimate(for: self) {
            driver.animate(with: update)
        } else {
            driver.moveCamera(update)
        }
    }

    /// The camera update for a fit to `bounds`, the move behind every location, building and venue
    /// selection.
    ///
    /// `GMSCameraUpdate.fit` always lands at bearing 0. With a fixed bearing, the fit's zoom has to be
    /// worked out for the area seen from that bearing instead: turned afterwards at the same zoom, a tall
    /// area on a portrait screen ends up across it and runs off both sides. So the area is fitted for the
    /// fixed bearing here, with the same 64 point margin `GMSCameraUpdate.fit` keeps, and the camera lands
    /// there in one move with every other limit applied.
    @MainActor
    func fitUpdate(for bounds: GMSCoordinateBounds) -> GMSCameraUpdate {
        guard let mapView, let bearing = cameraLimits?.fixedBearingDegrees else { return GMSCameraUpdate.fit(bounds) }

        let viewport = Self.viewportInsets(of: mapView)
        let available = CGSize(
            width: mapView.bounds.width - viewport.left - viewport.right - 2 * Self.fitMargin,
            height: mapView.bounds.height - viewport.top - viewport.bottom - 2 * Self.fitMargin)
        let fit = Self.fit(southWest: bounds.southWest, northEast: bounds.northEast, bearing: bearing, in: available)
        let camera = GMSCameraPosition(target: fit.center, zoom: fit.zoom ?? mapView.maxZoom, bearing: bearing, viewingAngle: mapView.camera.viewingAngle)
        return GMSCameraUpdate.setCamera(cameraWithinLimits(camera))
    }

    /// The margin `GMSCameraUpdate.fit(_:)` keeps around the area when no padding is given.
    private static let fitMargin: CGFloat = 64

    /// The part of the map view Google centres and fits a camera in: the view inset by its `padding`, and
    /// by its safe area as `paddingAdjustmentBehavior` adds it (`.always` by default). Shared with the route
    /// renderer's fit, so a location fit and a route fit leave the same room.
    @MainActor
    static func viewportInsets(of mapView: GMSMapView) -> UIEdgeInsets {
        let padding = mapView.padding
        let safeArea = mapView.safeAreaInsets
        switch mapView.paddingAdjustmentBehavior {
        case .always:
            return UIEdgeInsets(
                top: padding.top + safeArea.top, left: padding.left + safeArea.left,
                bottom: padding.bottom + safeArea.bottom, right: padding.right + safeArea.right)
        case .automatic:
            return UIEdgeInsets(
                top: Swift.max(padding.top, safeArea.top), left: Swift.max(padding.left, safeArea.left),
                bottom: Swift.max(padding.bottom, safeArea.bottom), right: Swift.max(padding.right, safeArea.right))
        case .never:
            return padding
        @unknown default:
            return padding
        }
    }

    /// The centre and zoom that fit the box from `southWest` to `northEast` into `size` points, seen from
    /// `bearing`. Worked out on the Web Mercator plane, where the box is a rectangle: turned by `bearing`,
    /// it spans `w |cos b| + h |sin b|` across the screen and `w |sin b| + h |cos b|` down it. `zoom` is
    /// `nil` for a box of no size, which any zoom fits.
    static func fit(
        southWest: CLLocationCoordinate2D, northEast: CLLocationCoordinate2D, bearing: CLLocationDirection, in size: CGSize
    ) -> (center: CLLocationCoordinate2D, zoom: Float?) {
        let west = worldX(longitude: southWest.longitude)
        let east = worldX(longitude: northEast.longitude)
        let north = worldY(latitude: northEast.latitude)
        let south = worldY(latitude: southWest.latitude)
        let center = CLLocationCoordinate2D(latitude: latitude(worldY: (north + south) / 2), longitude: (southWest.longitude + northEast.longitude) / 2)

        let (width, height) = (abs(east - west), abs(south - north))
        let radians = bearing * .pi / 180
        let (cosine, sine) = (abs(cos(radians)), abs(sin(radians)))
        let across = width * cosine + height * sine
        let down = width * sine + height * cosine
        guard across > 0 || down > 0 else { return (center, nil) }

        let scale = Swift.min(
            across > 0 ? Double(Swift.max(size.width, 1)) / across : .greatestFiniteMagnitude,
            down > 0 ? Double(Swift.max(size.height, 1)) / down : .greatestFiniteMagnitude)
        return (center, Float(log2(scale)))
    }

    /// Web Mercator world coordinates at zoom 0, on the 256 point tile Google's zoom levels count from.
    private static let worldSize = 256.0

    private static func worldX(longitude: CLLocationDegrees) -> Double {
        (longitude + 180) / 360 * worldSize
    }

    private static func worldY(latitude: CLLocationDegrees) -> Double {
        let sine = sin(latitude * .pi / 180)
        return (0.5 - log((1 + sine) / (1 - sine)) / (4 * .pi)) * worldSize
    }

    private static func latitude(worldY y: Double) -> CLLocationDegrees {
        let n = .pi * (1 - 2 * y / worldSize)
        return atan(sinh(n)) * 180 / .pi
    }

    /// The camera the last correction was asked from, and where it asked to go. See ``reapplyCameraLimits()``.
    private var lastCorrection: (from: GMSCameraPosition, to: GMSCameraPosition)?

    /// Test injection point for the correction's camera verb; `nil` drives the map view. Mirrors
    /// `GMCameraOperator.cameraDriverOverride`.
    @MainActor internal var correctionDriverOverride: (any GMCameraDriving)?

    private static let zoomTolerance: Float = 0.0001

    private static func isSame(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
    }

    private static func isSame(_ a: GMSCameraPosition, _ b: GMSCameraPosition) -> Bool {
        isSame(a.target, b.target) && abs(a.zoom - b.zoom) <= zoomTolerance
            // A bearing is a compass direction, so 359.999 and 0 are the same.
            && abs((a.bearing - b.bearing + 540).truncatingRemainder(dividingBy: 360) - 180) <= 0.01
            && abs(a.viewingAngle - b.viewingAngle) <= 0.01
    }

    /// The steepest tilt Google Maps applies. Beyond it the engine clamps silently.
    static let maxViewingAngle = 45.0

    // Unused: Google Maps markers are hit-tested by the engine's own marker delegate, so there is
    // no tolerance query to widen or narrow here.
    public var expandedTapAreaEnabled: Bool = true

    /// Written by `MPMapControlInternal` when it is created and read by `GMCameraOperator` and the directions
    /// renderer, all on the main actor (SPEX-2060).
    public var cameraAnimationsEnabled: Bool = true

    /// Stored for the protocol, but unused: Google Maps draws the info window into the map as an image, which
    /// VoiceOver cannot focus, so the selection announcement speaks for it instead (SPEX-2065).
    public var moveAccessibilityFocusToInfoWindow: Bool = true

    // Unused
    public var wallExtrusionOpacity: Double = 0

    // Unused
    public var featureExtrusionOpacity: Double = 0

    private func configureMapsIndoorsModuleLicensing() async {
        await MainActor.run { applyLicensedZoomCap() }
        if let solutionModules = MPMapsIndoors.shared.solution?.modules {
            await renderer?.setIsModel2DEnabled(solutionModules.contains("2dmodels"))
            await renderer?.setIsFloorPlanEnabled(solutionModules.contains("floorplan"))
        }
    }
}
