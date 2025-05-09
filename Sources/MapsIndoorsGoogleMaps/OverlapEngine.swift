import Foundation
import GameplayKit
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

class Elem: NSObject {
    var min: (Float, Float) = (0.0, 0.0)
    var max: (Float, Float) = (0.0, 0.0)
    
    let id: String

    required init(id: String, min: (Float, Float) = (0, 0), max: (Float, Float) = (0, 0)) {
        self.min = min
        self.max = max
        self.id = id
    }

    var minFloat: vector_float2 {
        return vector_float2(min.0, min.1)
    }

    var maxFloat: vector_float2 {
        return vector_float2(max.0, max.1)
    }

    // MARK: - NSObject Overrides (Important for consistent behavior)

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Elem else {
            return false
        }
        return self.id == other.id
    }

    override var hash: Int {
        return id.hashValue
    }

    override var description: String {
        return "Elem(min: \(min), max: \(max))"
    }

}

actor OverlapEngine {
    
    private let intersectionThreshold = 0.15 // percent
    
    private var views = [ViewState]()
    private var projection: GMSProjection? = nil

    private let tree = Locked<GKQuadtree<Entry>?>(value: nil)
    private var entries = [String: Entry]()

    init() { }

    private func buildTree(viewStates: [ViewState]) async {
        tree.locked { tree in
            tree = GKQuadtree(boundingQuad: GKQuad(quadMin: vector_float2(-10_000, -10_000), quadMax: vector_float2(10_000, 10_000)), minimumCellSize: 18)
        }
        
        for view in viewStates {
            guard let projection else { continue }
            let viewEntry = await Entry(viewState: view, projection: projection)
            entries[view.id] = viewEntry
            await addEntry(entry: viewEntry)
        }
    }

    /**
     Run collision checks for each view state, against all other view states - and handle potential collisions by computing delta operations
     */
    func computeDeltas(views: [ViewState], projection: GMSProjection, overlapPolicy: MPCollisionHandling) async throws {
        guard overlapPolicy != .allowOverLap else { return }
        
        self.views = views.sorted(by: { a, b in a.id < b.id })
        self.projection = projection
        
        self.entries.removeAll(keepingCapacity: true)
        
        await buildTree(viewStates: views)
        
        for view in views {
            try Task.checkCancellation()
            if let current = self.entries[view.id], let bounds = await current.viewState.bounds {
                var collisions = [Entry]()
                tree.locked { tree in
                    collisions.append(contentsOf: tree?.elements(in: GKQuad(quadMin: bounds.gkBoundingBoxMin, quadMax: bounds.gkBoundingBoxMax)) ?? [])
                }

                for hit in collisions {
                    try Task.checkCancellation()
                    guard hit.id != current.id else { continue }
                    let (winner, loser) = self.decideCollision(a: current, b: hit)
                    await self.resolveCollision(winnerEntry: winner, loserEntry: loser, overlapPolicy: overlapPolicy)
                }
            }
        }
    }

    /**
     Returns a (winner, loser)-tuple.
     The winner is determined by the smallest geometry size (poiArea). In case they are equal - we use the lat/lng to determine a winner.
     The most northern or the most eastern point wins.
     If a viewstate is "selected", it should always be the winner!
     */
    private func decideCollision(a: Entry, b: Entry) -> (Entry, Entry) {
        if a.viewState.forceRender.value == true { return (a, b) }
        if b.viewState.forceRender.value == true { return (b, a) }

        // 1. Compare based on poiArea size
        if a.viewState.poiArea.value != b.viewState.poiArea.value {
            return a.viewState.poiArea.value < b.viewState.poiArea.value ? (a, b) : (b, a)
        }

        // 2. Compare based on id - alphabetically
        if a.viewState.poiArea.value == b.viewState.poiArea.value {
            let aName = a.viewState.id
            let bName = b.viewState.id
            if aName != bName {
                return aName < bName ? (a, b) : (b, a)
            }
        }

        return (a, b)
    }

    /**
     Decide what delta operations should be commited to view states in order to resolve the collision according to the set MPCollisionHandling.
     Here we know that a collision has happened between two entries (and their underlying view states), so we remove them from the rtree -
     make the necessary state mutations to resolve the conflict - and re-add them to the rtree (in order to update their hitbox representation).
     */
    private func resolveCollision(winnerEntry: Entry, loserEntry: Entry, overlapPolicy: MPCollisionHandling) async {
        await removeEntry(entry: winnerEntry)
        await removeEntry(entry: loserEntry)

        switch overlapPolicy {
        case .removeIconFirst:
            await removeIconFirst(winnerState: winnerEntry.viewState, loserState: loserEntry.viewState)
        case .removeLabelFirst:
            await removeLabelFirst(winnerState: winnerEntry.viewState, loserState: loserEntry.viewState)
        case .removeIconAndLabel:
            await removeIconAndLabel(winnerState: winnerEntry.viewState, loserState: loserEntry.viewState)
        default:
            break
        }

        await addEntry(entry: winnerEntry)
        await addEntry(entry: loserEntry)
    }

    private func removeIconAndLabel(winnerState: ViewState, loserState: ViewState) async {
        let winner = await winnerState.bounds ?? CGRect(x: -1000, y: -1000, width: 1, height: 1)
        let loser = await loserState.bounds ?? CGRect(x: -2000, y: -2000, width: 1, height: 1)
        if winner.intersects(with: loser, byAtLeast: intersectionThreshold) {
            if loserState.forceRender.value == true && winnerState.forceRender.value == true { return }
            await winnerState.setMarkerState(state: .INVISIBLE)
        }
    }

    /**
     Remove the icon(s) first, to attempt to resolve the collision - if that isn't enough, remove label(s)
     */
    private func removeIconFirst(winnerState: ViewState, loserState: ViewState) async {
        var winner = await winnerState.bounds ?? CGRect(x: -1000, y: -1000, width: 1, height: 1)
        var loser = await loserState.bounds ?? CGRect(x: -2000, y: -2000, width: 1, height: 1)
        let winnerHasLabel = await winnerState.markerState.isLabelVisible
        let winnerHasIcon = await winnerState.markerState.isIconVisible
        let loserHasLabel = await loserState.markerState.isLabelVisible
        var loserHasIcon = await loserState.markerState.isIconVisible

        let winnersOriginalState = await winnerState.markerState
        let losersOriginalState = await loserState.markerState

        // Attempt to remove the loser's icon
        if loserHasLabel {
            await loserState.setMarkerState(state: .VISIBLE_LABEL)
        }
        loser = await loserState.bounds ?? CGRect(x: -2000, y: -2000, width: 1, height: 1)

        // Check if that solved the collision
        if winner.intersects(with: loser, byAtLeast: intersectionThreshold) {
            
            // Revert the loser, we will try to attempt solving the collision by tweaking the winner instaed
            await loserState.setMarkerState(state: losersOriginalState)
            loser = await loserState.bounds ?? CGRect(x: -2000, y: -2000, width: 1, height: 1)
            
            // Attempt to remove the winner's label
            if winnerHasLabel {
                await winnerState.setMarkerState(state: .VISIBLE_LABEL)
            }
            
            winner = await winnerState.bounds ?? CGRect(x: -1000, y: -1000, width: 1, height: 1)
            
            // Check if that solved the collision
            if winner.intersects(with: loser, byAtLeast: intersectionThreshold) {
                // If not, pick the nuclear option and kill the loser
                await winnerState.setMarkerState(state: winnersOriginalState)
                await loserState.setMarkerState(state: .INVISIBLE)
            }
        }
    }

    /**
     Remove the label(s) first, to attempt to resolve the collision - if that isn't enough, remove icons(s)
     */
    private func removeLabelFirst(winnerState: ViewState, loserState: ViewState) async {
        var winner = await winnerState.bounds ?? CGRect(x: -1000, y: -1000, width: 1, height: 1)
        var loser = await loserState.bounds ?? CGRect(x: -2000, y: -2000, width: 1, height: 1)
        let winnerHasLabel = await winnerState.markerState.isLabelVisible
        let winnerHasIcon = await winnerState.markerState.isIconVisible
        var loserHasLabel = await loserState.markerState.isLabelVisible
        let loserHasIcon = await loserState.markerState.isIconVisible
        
        let winnersOriginalState = await winnerState.markerState
        let losersOriginalState = await loserState.markerState

        // Attempt to remove the loser's label
        if loserHasIcon {
            await loserState.setMarkerState(state: .VISIBLE_ICON)
        }
        loser = await loserState.bounds ?? CGRect(x: -2000, y: -2000, width: 1, height: 1)

        // Check if that solved the collision
        if winner.intersects(with: loser, byAtLeast: intersectionThreshold) {
            
            // Revert the loser, we will try to attempt solving the collision by tweaking the winner instaed
            await loserState.setMarkerState(state: losersOriginalState)
            loser = await loserState.bounds ?? CGRect(x: -2000, y: -2000, width: 1, height: 1)
            
            // Attempt to remove the winner's label
            if winnerHasIcon {
                await winnerState.setMarkerState(state: .VISIBLE_ICON)
            }
            
            winner = await winnerState.bounds ?? CGRect(x: -1000, y: -1000, width: 1, height: 1)
            
            // Check if that solved the collision
            if winner.intersects(with: loser, byAtLeast: intersectionThreshold) {
                // If not, pick the nuclear option and kill the loser
                await winnerState.setMarkerState(state: winnersOriginalState)
                await loserState.setMarkerState(state: .INVISIBLE)
            }
        }
    }
    
    func addEntry(entry: Entry) async {
        if let bounds = await entry.viewState.bounds {
            // Add hit detection points for all four corners, edges and center
            tree.locked { tree in
                // Four corners
                let _1 = tree?.add(entry, at: bounds.gkBoundingBoxMin)
                let _2 = tree?.add(entry, at: bounds.gkBoundingBoxMax)
                let _3 = tree?.add(entry, at: vector_float2(bounds.gkBoundingBoxMax.x, bounds.gkBoundingBoxMin.y))
                let _4 = tree?.add(entry, at: vector_float2(bounds.gkBoundingBoxMin.x, bounds.gkBoundingBoxMax.y))
                
                // Center
                let _5 = tree?.add(entry, at: vector_float2(bounds.gkBoundingBoxMax.x - bounds.gkBoundingBoxMin.x, bounds.gkBoundingBoxMax.y - bounds.gkBoundingBoxMin.y))
                
                // Four edge center points
                let _6 = tree?.add(entry, at: vector_float2(bounds.gkBoundingBoxMin.x + ((bounds.gkBoundingBoxMax.x - bounds.gkBoundingBoxMin.x)/2), bounds.gkBoundingBoxMin.y))
                let _7 = tree?.add(entry, at: vector_float2(bounds.gkBoundingBoxMin.x + ((bounds.gkBoundingBoxMax.x - bounds.gkBoundingBoxMin.x)/2), bounds.gkBoundingBoxMax.y))
                let _8 = tree?.add(entry, at: vector_float2(bounds.gkBoundingBoxMin.x, bounds.gkBoundingBoxMin.y + ((bounds.gkBoundingBoxMax.y - bounds.gkBoundingBoxMin.y)/2)))
                let _9 = tree?.add(entry, at: vector_float2(bounds.gkBoundingBoxMax.x, bounds.gkBoundingBoxMin.y + ((bounds.gkBoundingBoxMax.y - bounds.gkBoundingBoxMin.y)/2)))
            
                entry.nodes.append(contentsOf: [_1, _2, _3, _4, _5, _6, _7, _8, _9].compactMap { $0 } )
            }
            
        }
    }

    func removeEntry(entry: Entry) async {
        tree.locked { tree in
            for node in entry.nodes {
                tree?.remove(entry, using: node)
            }
        }
    }
    
}

extension CGRect {
    var gkBoundingBoxMin: SIMD2<Float> {
        return SIMD2<Float>(Float(minX), Float(minY))
    }

    var gkBoundingBoxMax: SIMD2<Float> {
        return SIMD2<Float>(Float(maxX), Float(maxY))
    }
}

class Entry: NSObject {
    weak var viewState: ViewState!
    let id: String
    weak var projection: GMSProjection!
    
    var nodes = [GKQuadtreeNode]()
    
    required init(viewState: ViewState, projection: GMSProjection) async {
        self.viewState = viewState
        self.projection = projection
        id = viewState.id
    }

}

/// AI generated
extension CGRect {
    /// Checks if the current CGRect intersects with another CGRect by at least a specified percentage.
    ///
    /// - Parameters:
    ///   - rect2: The other CGRect to check for intersection.
    ///   - threshold: A value between 0.0 and 1.0 (inclusive) representing the minimum percentage of overlap required.
    ///                For example, 0.2 means at least 20% overlap is needed to return true.
    /// - Returns: `true` if the intersection area is at least the specified percentage of either of the two rectangles,
    ///            otherwise `false`.
    public func intersects(with rect2: CGRect, byAtLeast threshold: CGFloat) -> Bool {
        guard threshold >= 0.0 && threshold <= 1.0 else {
            print("Warning: Intersection threshold should be between 0.0 and 1.0. Returning false.")
            return false
        }

        let intersection = self.intersection(rect2)

        // If there is no intersection, return false immediately.
        guard !intersection.isNull else {
            return false
        }

        let selfArea = self.width * self.height
        let otherArea = rect2.width * rect2.height
        let intersectionArea = intersection.width * intersection.height

        // Check if the intersection area is at least the threshold percentage of either rectangle's area.
        return (intersectionArea / selfArea >= threshold) || (intersectionArea / otherArea >= threshold)
    }
}
