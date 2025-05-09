import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

actor Renderer {
    private weak var map: GMSMapView?

    init(map: GMSMapView?) {
        self.map = map
    }

    var is2dModelsEnabled = false

    var isFloorPlanEnabled = false
    
    
    func setIsModel2DEnabled(_ value: Bool) {
        is2dModelsEnabled = value
    }
    
    func setIsFloorPlanEnabled(_ value: Bool) {
        isFloorPlanEnabled = value
    }

    // Keeping track of active view states (things in view)
    private var views = [String: ViewState]()
    
    private let overlapEngine = OverlapEngine()
    
    private var lock = AsyncSemaphore(value: 1)

    func setViewModels(models: [any MPViewModel], collision: MPCollisionHandling, forceClear: Bool) async throws {
        try Task.checkCancellation()

        let ids = models.map(\.id)
        let newSet = Set<String>(ids)
        let oldSet = Set<String>(views.keys)
        let noLongerInView = oldSet.subtracting(newSet)

        // Compute which view state instances are in view
        var viewStatesInView = [ViewState]()
        viewStatesInView.reserveCapacity(ids.count)
        for modelId in ids {
            if let viewState = views[modelId] {
                viewStatesInView.append(viewState)
            }
        }

        try Task.checkCancellation()

        if let projection = await stage0AcquireProjection() {
            try Task.checkCancellation()
            
            await stage1PurgeViewStates(noLongerInView: noLongerInView, forceClear: forceClear)
            
            try Task.checkCancellation()
            
            try await stage2ComputeDeltas(models: models)
            
            try Task.checkCancellation()
            
            let viewStatesInView = await computeViewStatesInView(ids: ids)
            
            try Task.checkCancellation()
            
            try await stage3OverlapDetection(collision: collision, projection: projection, inView: viewStatesInView)
            
            try Task.checkCancellation()
            
            try await stage4ApplyDeltas(inView: viewStatesInView)
        }
    }

    // Read the projection (requires main thread)
    @MainActor
    func stage0AcquireProjection() async -> GMSProjection? {
        await map?.projection
    }

    // Clean up viewstates outside of the current view
    func stage1PurgeViewStates(noLongerInView: Set<String>, forceClear: Bool) async {
        let currentTime = CFAbsoluteTimeGetCurrent()
        for id in noLongerInView {
            // Kill the view state if either:
            // - The total number of active view states exceeds the limit,
            // - It has been >10 seconds since we last viewed the view state
            // - forceClear flag is true (likely due to a floor change)
            let timeLimitSec = 10.0
            let viewsLimit = 250
            let noOfActiveViewStates = views.count
            let timeSinceLastViewed = await currentTime - (views[id]?.lastTimeTag ?? 0)

            if timeSinceLastViewed > timeLimitSec || noOfActiveViewStates > viewsLimit || forceClear {
                if let view = views[id] {
                    await view.destroy()
                }
                views[id] = nil
            }
            
            // Let the view model know that it is not visualized required atm.
            if let view = views[id] {
                await view.setMarkedAsNoLongerInView()
            }
        }
    }

    // Compute which delta operations needs to be applied to each view state, to reflect the model's values
    func stage2ComputeDeltas(models: [any MPViewModel]) async throws {
        guard let map else { return }

        for model in models {
            try Task.checkCancellation()
            // Compute delta between view state and view model, if one exists
            if let view = self.views[model.id] {
                await view.computeDelta(newModel: model)
            } else {
                // Otherwise, create view state
                let view = await self.initViewState(viewModel: model, map: map)
                await view.computeDelta(newModel: model)
                self.views[model.id] = view
            }
        }
    }

    func initViewState(viewModel: any MPViewModel, map: GMSMapView) async -> ViewState {
        await ViewState(viewModel: viewModel, map: map, is2dModelEnabled: is2dModelsEnabled, isFloorPlanEnabled: isFloorPlanEnabled)
    }

    // Compute which view state instances are in view after stage 2
    func computeViewStatesInView(ids: [String]) async -> [ViewState] {
        var viewStatesInView = [ViewState]()
        viewStatesInView.reserveCapacity(ids.count)
        for modelId in ids {
            if let viewState = views[modelId] {
                viewStatesInView.append(viewState)
            }
        }
        return viewStatesInView
    }

    // Perform overlap detection on all view states in view
    func stage3OverlapDetection(collision: MPCollisionHandling, projection: GMSProjection, inView: [ViewState]) async throws {
        guard collision != .allowOverLap else { return }
        try await self.overlapEngine.computeDeltas(views: inView, projection: projection, overlapPolicy: collision)
    }

    // Apply the previously computed delta to each view state in view
    func stage4ApplyDeltas(inView: [ViewState]) async throws {
        for viewState in inView {
            try Task.checkCancellation()
            await viewState.applyDelta()
        }
    }
}
