import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

class Renderer {
    private weak var map: GMSMapView?

    required init(map: GMSMapView?) {
        self.map = map
    }

    var is2dModelsEnabled = false

    var isFloorPlanEnabled = false

    // Keeping track of active view states (things in view)
    @MainActor private var views = [String: ViewState]()

    func setViewModels(models: [any MPViewModel], collision: MPCollisionHandling, forceClear: Bool) async throws {
        try Task.checkCancellation()
        
        let ids = models.map(\.id)
        let newSet = Set<String>(ids)
        let oldSet = await Set<String>(self.views.keys)
        let noLongerInView = oldSet.subtracting(newSet)
        
        try Task.checkCancellation()

        // Compute which view state instances are in view
        var viewStatesInView = [ViewState]()
        viewStatesInView.reserveCapacity(ids.count)
        for modelId in ids {
            if let viewState = await self.views[modelId] {
                viewStatesInView.append(viewState)
            }
        }
        
        try Task.checkCancellation()

        if let projection = await self.stage0AcquireProjection() {
            try Task.checkCancellation()
            await self.stage1PurgeViewStates(noLongerInView: noLongerInView, forceClear: forceClear)
            try Task.checkCancellation()
            await self.stage2ComputeDeltas(models: models)
            try Task.checkCancellation()
            let viewStatesInView = await self.computeViewStatesInView(ids: ids)
            try Task.checkCancellation()
            await self.stage3OverlapDetection(collision: collision, projection: projection, inView: viewStatesInView)
            try Task.checkCancellation()
            await self.stage4ApplyDeltas(inView: viewStatesInView)
        }
    }

    // Read the projection (requires main thread)
    @MainActor
    func stage0AcquireProjection() async -> GMSProjection? {
        map?.projection
    }

    // Clean up viewstates outside of the current view
    @MainActor
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
        }
    }

    // Compute which delta operations needs to be applied to each view state, to reflect the model's values
    func stage2ComputeDeltas(models: [any MPViewModel]) async {
        guard let map else { return }

        _ = await withTaskGroup(of: Void.self) { group in
            for model in models {
                _ = group.addTaskUnlessCancelled(priority: .high) {
                    // Compute delta between view state and view model, if one exists
                    if let view = await self.views[model.id] {
                        await view.computeDelta(newModel: model)
                    } else {
                        // Otherwise, create view state
                        let view = await self.initViewState(viewModel: model, map: map)
                        await view.computeDelta(newModel: model)
                        Task { @MainActor [weak self] in
                            self?.views[model.id] = view
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func initViewState(viewModel: any MPViewModel, map: GMSMapView) async -> ViewState {
        await ViewState(viewModel: viewModel, map: map, is2dModelEnabled: is2dModelsEnabled, isFloorPlanEnabled: isFloorPlanEnabled)
    }

    // Compute which view state instances are in view after stage 2
    func computeViewStatesInView(ids: [String]) async -> [ViewState] {
        var viewStatesInView = [ViewState]()
        viewStatesInView.reserveCapacity(ids.count)
        for modelId in ids {
            if let viewState = await views[modelId] {
                viewStatesInView.append(viewState)
            }
        }
        return viewStatesInView
    }

    // Perform overlap detection on all view states in view
    func stage3OverlapDetection(collision: MPCollisionHandling, projection: GMSProjection, inView: [ViewState]) async {
        guard collision != .allowOverLap else { return }
        let engine = await OverlapEngine(views: inView, projection: projection, overlapPolicy: collision)
        await engine.computeDeltas()
    }

    // Apply the previously computed delta to each view state in view
    func stage4ApplyDeltas(inView: [ViewState]) async {
        _ = await withTaskGroup(of: Void.self) { group in
            for viewState in inView {
                _ = group.addTaskUnlessCancelled(priority: .high) {
                    await viewState.applyDelta()
                }
            }
        }
    }
}
