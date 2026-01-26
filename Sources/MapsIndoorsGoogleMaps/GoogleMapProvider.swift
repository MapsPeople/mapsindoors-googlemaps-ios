import Foundation
import GoogleMaps
import MapsIndoorsCore

public class GoogleMapProvider: MPMapProvider {
    public let model2DResolutionLimit = 200

    // Unused on Google Maps
    public var enableNativeMapBuildings: Bool = false

    public var routingService: MPExternalDirectionsService {
        GMDirectionsService(apiKey: googleApiKey! as String)
    }

    public var distanceMatrixService: MPExternalDistanceMatrixService {
        GMDistanceMatrixService(apiKey: googleApiKey! as String)
    }

    public var customInfoWindow: MPCustomInfoWindow?

    public func reloadTilesForFloorChange() {}

    private var renderer: Renderer?
    private var _routeRenderer: GMRouteRenderer?
    private var tileProvider: GMTileProvider?

    public var collisionHandling: MPCollisionHandling = .allowOverLap

    public var cameraOperator: MPCameraOperator {
        GMCameraOperator(gmsView: mapView)
    }

    public var routeRenderer: MPRouteRenderer {
        if _routeRenderer != nil {
            return _routeRenderer!
        } else {
            _routeRenderer = GMRouteRenderer(map: mapView)
            return _routeRenderer!
        }
    }

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
    }

    public func setViewModels(models: [any MPViewModel], forceClear: Bool) async {
        await configureMapsIndoorsModuleLicensing()
        do {
            try await renderer?.setViewModels(models: models, collision: collisionHandling, forceClear: forceClear)
        } catch { /* do nothing */ }
    }

    public var view: UIView? {
        mapView
    }

    public var MPaccessibilityElementsHidden: Bool {
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
