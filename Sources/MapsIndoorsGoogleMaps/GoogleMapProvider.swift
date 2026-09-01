import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

// SAFETY: (SPEX-1975) GoogleMapProvider wraps main-thread-only Google Maps UI and is
// only ever accessed on the main actor, so it is safe to share by that convention. (MPMapProvider
// is Sendable; the type-system proof is deferred with the wider provider-isolation work.)
public class GoogleMapProvider: MPMapProvider, @unchecked Sendable {
    public let model2DResolutionLimit = 200

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
        GMCameraOperator(gmsView: mapView)
    }

    public var routeRenderer: MPRouteRenderer { _routeRenderer! }

    @MainActor
    public func setTileProvider(tileProvider: MPTileProvider) async {
        self.tileProvider?.map = nil
        self.tileProvider = GMTileProvider(provider: tileProvider)
        self.tileProvider?.map = mapView
    }

    public var delegate: MPMapProviderDelegate? {
        set {
            mapViewDelegate?.mapsIndoorsDelegate = newValue
        }
        get {
            mapViewDelegate?.mapsIndoorsDelegate
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

        self.mapView?.isBuildingsEnabled = false
        self.mapView?.isIndoorEnabled = false
        self.mapView?.setMinZoom(1, maxZoom: 21)

        self.googleApiKey = googleApiKey

        positionPresenter = GMPositionPresenter(map: mapView)

        cameraPosition = GMCameraPosition(cameraPosition: GMSMutableCameraPosition())

        mapViewDelegate = GoogleMapViewDelegate(googleMapProvider: self)
        if let originalDelegate = self.mapView?.delegate {
            mapViewDelegate?.originalMapViewDelegate = originalDelegate
        }
        self.mapView?.delegate = mapViewDelegate

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

    public var mpAccessibilityElementsHidden: Bool {
        get {
            mapView?.accessibilityElementsHidden ?? true
        }
        set {
            mapView?.accessibilityElementsHidden = newValue
        }
    }

    public var padding: UIEdgeInsets {
        get {
            mapView?.padding ?? UIEdgeInsets.zero
        }
        set {
            mapView?.padding = newValue
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

    // Unused
    public var wallExtrusionOpacity: Double = 0

    // Unused
    public var featureExtrusionOpacity: Double = 0

    private func configureMapsIndoorsModuleLicensing() async {
        if let solutionModules = MPMapsIndoors.shared.solution?.modules {
            await renderer?.setIsModel2DEnabled(solutionModules.contains("2dmodels"))
            await renderer?.setIsFloorPlanEnabled(solutionModules.contains("floorplan"))
        }
    }
}
