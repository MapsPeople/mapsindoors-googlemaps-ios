import Foundation
import GoogleMaps
@_spi(Private) import MapsIndoorsCore

extension BinaryFloatingPoint {
    var radians: Self {
        self * .pi / 180.0
    }
}

class GMRouteRenderer: MPRouteRenderer {
    private weak var map: GMSMapView?

    private var polylineColor = UIColor.black
    private var polyline: GMSPolyline?
    private var basePolyline: GMSPolyline?
    private var stampPolyline: GMSPolyline?  // arrow preset: a rotating sprite stamped along the line
    private var stampMarkers = [GMSMarker]()  // custom preset: flat markers along the line, rotated to the line bearing

    private static let casingOffset = 2.0  // default halo padding per side (total width = strokeWeight + 2 × this)
    private static let fallbackColor = UIColor(red: 48.0 / 255.0, green: 113.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)

    // Bumped per apply(); a tick from a superseded generation bails so a stale animation
    // frame can't clear or restyle a route that a newer apply() has already drawn.
    private var animationGeneration = 0
    private static var didLogDashedFallback = false

    /// A transparent stroke that stamps a coloured dot sprite along the line (Google's dotted look).
    private static func makeDottedStroke(color: UIColor, width: CGFloat) -> GMSStrokeStyle {
        let stroke = GMSStrokeStyle.solidColor(.clear)
        stroke.stampStyle = GMSSpriteStyle(image: dotImage(color: color, diameter: width))
        return stroke
    }

    private var animatedColor = UIColor.black
    private var animatedWidth: Float = 3.0
    private var animationPath: GMSMutablePath?
    private var animationPolyline: GMSPolyline?
    private var valueAnimator: RouteLineAnimator?
    // Coalescing guard for the flow pipeline: true while a display-link tick's geometry→draw round-trip is still
    // in flight. A tick arriving meanwhile is dropped instead of piling more geometry work onto `queue`, so a
    // long / dense route can't let the async pipeline lag wall-clock behind the display link (the natural
    // back-pressure the pre-CADisplayLink `queue.sync` flow had for free). Touched only on the main thread, so
    // it needs no lock.
    private var flowTickInFlight = false

    var routeMarkerDelegate: MPRouteMarkerDelegate?

    required init(map: GMSMapView?) {
        self.map = map
    }

    private var queue = DispatchQueue(label: "MapsIndoors.GoogleMapsRouteRenderer")

    func apply(
        model: RouteViewModelProducer, options: MPDirectionsRendererOptions,
        animate: Bool, duration: TimeInterval, pathSmoothing: Bool
    ) {
        let baseColor = options.strokeColor ?? GMRouteRenderer.fallbackColor
        let strokeColor = baseColor.withAlphaComponent(options.strokeOpacity?.doubleValue ?? 1.0)
        let strokeWeight = options.strokeWeight?.doubleValue ?? 4.0
        let strokeStyle = options.strokeStyle ?? .solid
        // Halo shows by default (a faint version of the line colour) unless explicitly disabled.
        let haloColor: UIColor? = (options.backgroundColorEnabled?.boolValue ?? true)
            ? (options.backgroundColor?.withAlphaComponent(options.backgroundColorOpacity?.doubleValue ?? 1.0)
                ?? baseColor.withAlphaComponent(0.3))
            : nil
        let haloWidth = strokeWeight + 2 * (options.backgroundColorWeight?.doubleValue ?? GMRouteRenderer.casingOffset)
        let repeating = options.animationRepeating
        let animationType = options.animationType ?? .flow
        // Independent travelling-overlay style (its own colour / opacity / weight) — solid and thinner
        // than the base line so both colours read. The static base line carries any dash/dot. Colour and
        // opacity are kept separate so pulse can oscillate the alpha without losing the base tint.
        let overlayBaseColor = options.animatedOverlayColor ?? baseColor
        let overlayOpacity = options.animatedOverlayOpacity?.doubleValue ?? 1.0
        let overlayColor = overlayBaseColor.withAlphaComponent(overlayOpacity)
        let overlayWeight = options.animatedOverlayWeight?.doubleValue ?? strokeWeight
        // Static repeating stamp (arrow / custom icon) along the line — a decoration, independent of the
        // travelling animation. Resolved to the same bitmap both providers stamp.
        let stampType = options.stampType ?? .none
        let stampImage = RouteStampIcon.image(type: stampType, arrowStyle: options.arrowStyle ?? .chevron, color: options.stampColor ?? .white, customImage: options.stampImage)
        let stampSpacing = options.stampSpacing?.doubleValue ?? 24
        let stampScale = options.stampScale?.doubleValue ?? 1.0
        // The arrow rides a GMSSpriteStyle sprite (renders smaller than Mapbox, hence the larger factor) and
        // stays proportional to the line weight. A custom icon renders at a fixed 24 pt @1× base (× the scale
        // slider), so its on-screen size doesn't track the line weight or the source image's dimensions.
        let arrowSpriteSize = strokeWeight * 5.0 * stampScale
        let customMarkerSize = 24.0 * stampScale

        markerGeneration += 1
        for viewState in views {
            Task {
                await viewState.destroy()
            }
        }
        views.removeAll()

        queue.async {
            // Bump the generation on the serial queue (read back on the same queue in the
            // animation tick) so a superseded apply()'s ticks bail without a cross-thread read.
            self.animationGeneration += 1
            let generation = self.animationGeneration

            let gmsPath = GMSMutablePath()

            for c in model.polyline {
                gmsPath.add(c)
            }

            var path = gmsPath

            if pathSmoothing {
                path = PathSmoother.smoothenPath(withCoordinates: gmsPath)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Halo / casing — widest, drawn beneath the base line. A nil backgroundColor disables it.
                self.polyline?.map = nil
                self.polyline = nil
                if let haloColor {
                    let halo = GMSPolyline(path: path)
                    halo.geodesic = true
                    halo.strokeColor = haloColor
                    halo.strokeWidth = CGFloat(haloWidth)
                    halo.zIndex = Int32(MapOverlayZIndex.directionsOverlays.rawValue)
                    halo.map = self.map
                    self.polyline = halo
                }

                // Static styled base line (strokeColor / opacity / weight / style).
                self.basePolyline?.map = nil
                self.basePolyline = GMSPolyline(path: path)
                self.basePolyline?.geodesic = true
                self.basePolyline?.strokeColor = strokeColor
                self.basePolyline?.strokeWidth = CGFloat(strokeWeight)
                self.basePolyline?.zIndex = Int32(MapOverlayZIndex.directionsOverlays.rawValue) + 1
                self.applyStrokeStyle(strokeStyle, to: self.basePolyline, color: strokeColor, path: path)
                // Static line always visible; the flow overlay sits on top and no longer replaces it.
                self.basePolyline?.map = self.map

                // Repeating stamp along the line (above the base line, below the start/end markers).
                self.stampPolyline?.map = nil
                self.stampPolyline = nil
                for marker in self.stampMarkers { marker.map = nil }
                self.stampMarkers.removeAll()
                if let stampImage {
                    if stampType == .custom {
                        // Custom icons are placed as individual markers along the route (GMSSpriteStyle can't
                        // rotate an off-axis stamp cleanly); each lies flat and rotates to the line bearing, so
                        // the icon follows the line through turns like the arrow.
                        var routeCoords = [CLLocationCoordinate2D]()
                        if path.count() > 0 {
                            for i in 0...(path.count() - 1) { routeCoords.append(path.coordinate(at: i)) }
                        }
                        self.placeStampMarkers(icon: stampImage, along: routeCoords, sizePoints: customMarkerSize, spacingPoints: stampSpacing)
                    } else {
                        // Arrow: a clear stroke stamping a SQUARE sprite (icon centred, undistorted) repeated
                        // along the line. GMSSpriteStyle scales the sprite to the stroke width and repeats it
                        // touching, so the stroke width is the tile = the spacing, and the arrow is rotated a
                        // quarter-turn to point along travel.
                        let sprite = GMRouteRenderer.stampSprite(icon: stampImage, iconSize: arrowSpriteSize, tile: stampSpacing)
                        let stamp = GMSPolyline(path: path)
                        stamp.geodesic = true
                        stamp.strokeWidth = CGFloat(stampSpacing)
                        stamp.zIndex = Int32(MapOverlayZIndex.directionsOverlays.rawValue) + 3
                        let stroke = GMSStrokeStyle.solidColor(.clear)
                        stroke.stampStyle = GMSSpriteStyle(image: sprite)
                        stamp.spans = [GMSStyleSpan(style: stroke, segments: Double(max(Int(path.count()) - 1, 1)))]
                        stamp.map = self.map
                        self.stampPolyline = stamp
                    }
                }
            }

            if animate {
                var route = [CLLocationCoordinate2D]()
                if path.count() > 0 {
                    for i in 0...(path.count() - 1) {
                        route.append(path.coordinate(at: i))
                    }
                }

                let totalDistance = RouteFlowGeometry.totalLength(of: route)

                // The animator is a main-thread CADisplayLink, so create/start it on main. Per-frame geometry
                // is still built OFF main on `queue` (over the immutable `route` snapshot) and only the draw is
                // hopped back to main, so the display link never blocks main on the geometry compute.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.valueAnimator?.invalidate()
                    self.valueAnimator = RouteLineAnimator(
                        duration: duration,
                        repeatMode: repeating ? .infinite : .once,
                        startDelay: 0.1,
                        onProgress: { [weak self] progress in
                            guard let self else { return }
                            // Drop this tick if the previous one's geometry→draw round-trip hasn't finished, so
                            // ticks can't pile up on `queue` and lag behind the display link on a long route. The
                            // flag is cleared on every completion path below (draw, stopped, or superseded).
                            if self.flowTickInFlight { return }
                            self.flowTickInFlight = true
                            self.queue.async { [weak self] in
                                guard let self else { return }
                                guard generation == self.animationGeneration else {
                                    // Superseded by a newer apply(): free the slot (on main) so the next
                                    // animation's ticks aren't skipped forever, then drop this frame.
                                    DispatchQueue.main.async { [weak self] in self?.flowTickInFlight = false }
                                    return
                                }
                                let points: [CLLocationCoordinate2D]
                                switch animationType {
                                case .pulse:
                                    // The whole line stays drawn; only its opacity animates (below).
                                    points = route
                                case .comet:
                                    // A short bright segment of fixed length travels along the route — build
                                    // just that moving window each frame.
                                    let window = RouteFlowGeometry.cometWindow(progress: progress, totalLength: totalDistance)
                                    points = RouteFlowGeometry.subpath(of: route, fromDistance: window.tail, toDistance: window.head)
                                default:
                                    // flow: grow the revealed portion from the start up to the head.
                                    points = RouteFlowGeometry.subpath(of: route, fromDistance: 0, toDistance: progress * totalDistance)
                                }

                                let animatedPath = GMSMutablePath()
                                for coord in points {
                                    animatedPath.add(coord)
                                }

                                DispatchQueue.main.async { [weak self] in
                                    guard let self else { return }
                                    // Free the slot for the next tick whether or not this one draws.
                                    defer { self.flowTickInFlight = false }
                                    // The generation check on `queue` already dropped superseded ticks;
                                    // here just skip drawing once the animation has stopped.
                                    guard self.valueAnimator?.isRunning ?? false else { return }
                                    let line: GMSPolyline
                                    if let existing = self.animationPolyline {
                                        line = existing
                                    } else {
                                        line = GMSPolyline()
                                        line.zIndex = Int32(MapOverlayZIndex.directionsOverlays.rawValue) + 2
                                        line.map = self.map
                                        self.animationPolyline = line
                                    }
                                    // Re-apply the overlay style every tick so a live change takes effect
                                    // immediately. Solid + thinner than the base; the base carries any dash.
                                    line.path = animatedPath
                                    line.strokeWidth = CGFloat(overlayWeight)
                                    line.spans = []
                                    if animationType == .pulse {
                                        // Oscillate opacity dim → bright → dim each loop; never fully vanish.
                                        line.strokeColor = overlayBaseColor.withAlphaComponent(overlayOpacity * RouteFlowGeometry.pulseOpacityFactor(progress: progress))
                                    } else {
                                        line.strokeColor = overlayColor
                                    }
                                }
                            }
                        },
                        onEnd: { [weak self] in
                            // Natural (non-repeating) completion only. The base line is always visible, so just
                            // drop the flow overlay — but only if this animator is still current. A newer apply()
                            // (live type switch, next/prev leg, floor/options change) may have superseded it and
                            // be reusing animationPolyline; generation is confined to `queue`, so compare there.
                            guard let self else { return }
                            guard self.queue.sync(execute: { generation == self.animationGeneration }) else { return }
                            self.animationPolyline?.map = nil
                            self.animationPolyline = nil
                        })
                    self.valueAnimator?.start()
                }
            } else {
                // No flow — stop any prior animator and remove the lingering overlay so only the static line shows.
                DispatchQueue.main.async { [weak self] in
                    self?.valueAnimator?.invalidate()
                    self?.valueAnimator = nil
                    self?.animationPolyline?.map = nil
                    self?.animationPolyline = nil
                }
            }
            DispatchQueue.main.async { [weak self] in
                // start model render
                self?.renderMarker(model: model.start, type: .start)
                // end model render
                self?.renderMarker(model: model.end, type: .end)

                for stop in model.stops ?? [] {
                    self?.renderMarker(model: stop, type: .stop)
                }
            }
        }
    }

    /// Re-renders only the route markers, leaving every polyline — and the running animator — alone. `views`
    /// holds nothing but the marker view states, so tearing them all down and rebuilding from `model` is the
    /// marker-only counterpart of `apply`: a marker the model no longer carries (an endpoint pin whose display
    /// rule just went out of its zoom range) is destroyed and not recreated.
    func applyMarkers(model: RouteViewModelProducer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.markerGeneration += 1
            for viewState in self.views {
                Task {
                    await viewState.destroy()
                }
            }
            self.views.removeAll()

            self.renderMarker(model: model.start, type: .start)
            self.renderMarker(model: model.end, type: .end)

            for stop in model.stops ?? [] {
                self.renderMarker(model: stop, type: .stop)
            }
        }
    }

    func moveCamera(points path: [CLLocationCoordinate2D], animate _: Bool, durationMs _: Int, tilt: Float, fitMode: MPCameraViewFitMode, padding: UIEdgeInsets, maxZoom: Double?) {
        guard let map, path.count >= 2 else { return }

        let bounds = MPGeoBounds(points: path)
        // Cap the fitted zoom so a short leg can't zoom in past fitBoundsMaxZoom / automatedZoomLimit.
        let zoomCap = maxZoom.map { Float($0) } ?? .greatestFiniteMagnitude

        switch fitMode {
        case .northAligned:
            let zoom = min(adjustedZoom(path: path, heading: 0, insets: padding, tilt: 0), zoomCap)
            let pos = createCameraPosition(for: bounds.center.coordinate, zoom: zoom, bearing: 0, tilt: 0)
            DispatchQueue.main.async { map.animate(to: pos) }
        case .firstStepAligned, .startToEndAligned:
            guard path.count >= 2 else { break }
            let bearing = fitMode == .firstStepAligned ? MPGeometryUtils.bearingBetweenPoints(from: path[0], to: path[1]) : MPGeometryUtils.bearingBetweenPoints(from: path[0], to: path.last!)
            let zoom = min(adjustedZoom(path: path, heading: bearing, insets: padding, tilt: tilt), zoomCap)
            let pos = createCameraPosition(for: bounds.center.coordinate, zoom: zoom, bearing: bearing, tilt: tilt)
            DispatchQueue.main.async { map.animate(to: pos) }
        case .none:
            return
        default:
            break
        }
    }

    private func adjustedZoom(path: [CLLocationCoordinate2D], heading: CLLocationDirection, insets: UIEdgeInsets, tilt: Float) -> Float {
        guard let map else { return 0 }

        // Get center in WGS84, height and width in meters of the path
        let centerAndWidth = centerAndWidthOfPath(path, seenFromHeading: heading)
        let centerAndHeight = centerAndWidthOfPath(path, seenFromHeading: heading + 90)

        // Calculate a size factor for width and height
        let widthFactor = widthFactor(centerAndWidth: centerAndWidth)
        let heightFactor = heightFactor(centerAndHeight: centerAndHeight)

        // Derive zoom factor and zoom as the smallest factor:
        // below 1 we will zoom out,
        // above 1 we will zoom in
        var zoomFactor = min(widthFactor, heightFactor)
        let zoom = map.camera.zoom + log2(Float(zoomFactor))

        // Calculate ground resolution for the calculated zoom
        let groundResolution = groundResForLatitude(map.camera.target.latitude, zoom: Double(zoom))

        // For tilted fit modes (.firstStepAligned/.startToEndAligned)
        // perspective projection stretches the along-bearing extent of
        // the route on screen relative to its geographic distance —
        // the near half occupies more vertical pixels than the
        // orthographic calculation suggests. Apply the same 1.2x
        // safety margin to the along-bearing dimension that already
        // exists for the perpendicular one, but only when tilt > 0,
        // so .northAligned (the orthographic case) keeps its current
        // behavior.
        let heightMargin: Double = tilt > 0 ? 1.2 : 1.0

        // Calculate adjusted height and width based on insets
        let adjustedHeightDist = centerAndHeight.distance * heightMargin + groundResolution * insets.bottom + groundResolution * insets.top
        let adjustedWidthDist = centerAndWidth.distance * 1.2 + groundResolution * insets.left + groundResolution * insets.right

        // Calculate a size factor for width and height
        let adjustedHeightFactor = centerAndHeight.distance / adjustedHeightDist
        let adjustedWidthFactor = centerAndWidth.distance / adjustedWidthDist

        // Derive zoom factor and zoom as the smallest factor:
        zoomFactor = min(adjustedWidthFactor, adjustedHeightFactor)
        return zoom + log2(Float(zoomFactor))
    }

    struct PointDistanceResult {
        var position: CLLocationCoordinate2D
        var distance: CLLocationDistance
    }

    private func widthFactor(centerAndWidth: PointDistanceResult) -> Double {
        guard let map else { return 1 }

        let visibleRegion = map.projection.visibleRegion()
        let left = GMSGeometryInterpolate(visibleRegion.farLeft, visibleRegion.nearLeft, 0.5)
        let right = GMSGeometryInterpolate(visibleRegion.farRight, visibleRegion.nearRight, 0.5)
        let mapWidthDist = GMSGeometryDistance(left, right)
        return mapWidthDist / centerAndWidth.distance
    }

    private func heightFactor(centerAndHeight: PointDistanceResult) -> Double {
        guard let map else { return 1 }

        let visibleRegion = map.projection.visibleRegion()
        let top = GMSGeometryInterpolate(visibleRegion.farLeft, visibleRegion.farRight, 0.5)
        let bottom = GMSGeometryInterpolate(visibleRegion.nearLeft, visibleRegion.nearRight, 0.5)
        let mapHeightDist = GMSGeometryDistance(top, bottom)
        return mapHeightDist / centerAndHeight.distance
    }

    private func centerAndWidthOfPath(_ path: [CLLocationCoordinate2D], seenFromHeading heading: CLLocationDirection) -> PointDistanceResult {
        let center = centerOfPath(path)

        var bestLeftDist: CLLocationDistance = 0
        var bestRightDist: CLLocationDistance = 0
        for coordinate in path {
            let hypotenuseDist = GMSGeometryDistance(center, coordinate)
            let hypotenuseHeading = GMSGeometryHeading(center, coordinate)
            let relativeHeading = hypotenuseHeading - heading

            // Start with:   sin(relativeHeading)                = perpendicularDist/hypotenuseDist
            // Swap Sides:   perpendicularDist/hypotenuseDist    = sin(relativeHeading)
            // Thus:
            let perpendicularDist = sin(relativeHeading.radians) * hypotenuseDist
            if perpendicularDist > 0, perpendicularDist > bestRightDist {
                bestRightDist = perpendicularDist
            } else if -perpendicularDist > bestLeftDist {
                bestLeftDist = -perpendicularDist
            }
        }

        let distance = bestLeftDist + bestRightDist + 0.2
        let recenterHeading = heading + (bestRightDist > bestLeftDist ? 90 : -90)
        let position = GMSGeometryOffset(center, max(bestLeftDist, bestRightDist) - distance * 0.5, recenterHeading)

        return PointDistanceResult(position: position, distance: distance)
    }

    private func centerOfPath(_ path: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let gmsPath = GMSMutablePath()
        for coordinate in path {
            gmsPath.add(coordinate)
        }
        let bounds = GMSCoordinateBounds(path: gmsPath)
        return GMSGeometryInterpolate(bounds.northEast, bounds.southWest, 0.5)
    }

    /// Web-Mercator ground resolution at `zoom`: metres per screen point, on the 256 pt tile convention.
    private static func metersPerPoint(lat: Double, zoom: Double) -> Double {
        156543.03392 * cos(lat.radians) / pow(2, zoom)
    }

    private func groundResForLatitude(_ lat: Double, zoom: Double) -> Double {
        let screenScale = UIScreen.main.scale
        return GMRouteRenderer.metersPerPoint(lat: lat, zoom: zoom) / screenScale
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            // The animator's CADisplayLink must be torn down on the main thread.
            self?.valueAnimator?.invalidate()
            self?.valueAnimator = nil
            self?.polyline?.map = nil
            self?.basePolyline?.map = nil
            self?.animationPolyline?.map = nil
            self?.stampPolyline?.map = nil
            for marker in self?.stampMarkers ?? [] { marker.map = nil }

            self?.polyline = nil
            self?.basePolyline = nil
            self?.animationPolyline = nil
            self?.stampPolyline = nil
            self?.stampMarkers.removeAll()

            self?.markerGeneration += 1
            for viewState in self?.views ?? [] {
                Task {
                    await viewState.destroy()
                }
            }
            self?.views.removeAll()
        }
    }

    private func applyStrokeStyle(_ style: MPStrokeStyle, to polyline: GMSPolyline?, color: UIColor, path: GMSPath) {
        guard let polyline else { return }
        switch style {
        case .solid:
            polyline.spans = []
        case .dashed:
            // Google Maps iOS has no native dashed polyline; documented as Mapbox/Android/Web only.
            polyline.spans = []
            if !GMRouteRenderer.didLogDashedFallback {
                GMRouteRenderer.didLogDashedFallback = true
                MPLog.google.info("Dashed route style is not supported on Google Maps iOS; falling back to solid.")
            }
        case .dotted:
            let stroke = GMRouteRenderer.makeDottedStroke(color: color, width: polyline.strokeWidth)
            polyline.spans = [GMSStyleSpan(style: stroke, segments: Double(max(Int(path.count()) - 1, 1)))]
        @unknown default:
            polyline.spans = []
        }
    }

    private static func dotImage(color: UIColor, diameter: CGFloat) -> UIImage {
        let d = max(diameter, 1)
        // Dot fills the canvas height (so the sprite scales up to the line width) with a small
        // trailing gap, giving prominent, closely-spaced dots.
        let size = CGSize(width: d * 1.3, height: d)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        }
    }

    /// The arrow preset's sprite: the icon centred in a square tile, the rest transparent — like the
    /// dotted-line dot. ``GMSSpriteStyle`` compresses the image to a square, scales it to the stroke width
    /// and repeats it touching, so the square tile's side is the spacing and the icon drawn smaller inside
    /// leaves the gap. Rotated a quarter-turn so the right-pointing arrow glyph runs along the line
    /// (GMSSpriteStyle's vertical axis runs start→end).
    private static func stampSprite(icon: UIImage, iconSize: Double, tile: Double) -> UIImage {
        let side = max(tile, 1)  // square tile; its side is the repeat period (= stroke width)
        let target = min(max(iconSize, 1), side)  // icon no larger than its tile
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: side / 2, y: side / 2)
            cg.rotate(by: .pi / 2)
            icon.draw(in: aspectFitRect(for: icon.size, in: CGRect(x: -target / 2, y: -target / 2, width: target, height: target)))
        }
    }

    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Places markers of `icon` along the route for the custom stamp preset, each lying flat and rotated to the
    /// line's bearing so they tilt through turns (like the arrow). The screen-point spacing is converted to a
    /// world distance at the current zoom so the on-screen cadence matches the requested spacing (markers are
    /// then fixed in the world, so it drifts if the user zooms).
    private func placeStampMarkers(icon: UIImage, along route: [CLLocationCoordinate2D], sizePoints: Double, spacingPoints: Double) {
        guard let map, route.count > 1 else { return }
        // Convert the requested screen-point spacing to a world distance at the current zoom, using the
        // Web-Mercator ground resolution in metres per point — the cadence that matches what Mapbox draws
        // from `symbol-spacing`. Markers are world-anchored, so the on-screen cadence drifts if the user
        // then zooms.
        let metersPerPoint = GMRouteRenderer.metersPerPoint(lat: map.camera.target.latitude, zoom: Double(map.camera.zoom))
        // Floor the interval at totalLength / maxMarkers so a long or dense route stays under the marker
        // budget with the stamps spread evenly across the WHOLE route (not truncated at the start), and so
        // points() never builds a huge array only to discard most of it.
        let maxMarkers = 250.0
        let totalLength = RouteFlowGeometry.totalLength(of: route)
        let interval = max(spacingPoints * metersPerPoint, totalLength / maxMarkers, 0.5)
        let markerIcon = GMRouteRenderer.resized(icon, to: sizePoints)
        for sample in RouteFlowGeometry.pointsWithHeading(on: route, everyMeters: interval) {
            let marker = GMSMarker(position: sample.coordinate)
            marker.icon = markerIcon
            marker.isFlat = true  // lie flat and rotate with the line (like the arrow), not billboarded upright
            marker.rotation = sample.heading  // align the icon to the line's bearing at this point
            marker.isTappable = false  // pure decoration; don't intercept taps
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.zIndex = Int32(MapOverlayZIndex.directionsOverlays.rawValue) + 3
            marker.map = map
            stampMarkers.append(marker)
        }
    }

    private static func resized(_ image: UIImage, to side: Double) -> UIImage {
        let s = max(side, 1)
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { _ in
            image.draw(in: aspectFitRect(for: image.size, in: CGRect(x: 0, y: 0, width: s, height: s)))
        }
    }

    private var views = [ViewState]()

    // Bumped by every pass that tears the markers down — apply(), applyMarkers() and clear(). renderMarker
    // builds its ViewState asynchronously, so without this a marker from a superseded pass would land in
    // `views` after the newer pass had already cleared them, leaving a duplicate pin the newer pass never
    // destroys. Only ever touched on the main thread, so it needs no lock.
    private var markerGeneration = 0

    // Helper methods
    private func renderMarker(model: (any MPViewModel)?, type: MarkerType) {
        guard let model else { return }
        let generation = markerGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }

            let s = await ViewState(viewModel: model, map: map!, is2dModelEnabled: false, isFloorPlanEnabled: false)
            await s.computeDelta(newModel: model)
            await s.applyDelta()
            // Superseded while this marker was being built: applyDelta has already put it on the map, so tear
            // it down here rather than adding it to a `views` that no longer describes what is drawn.
            guard generation == self.markerGeneration else {
                await s.destroy()
                return
            }
            s.marker.value?.userData = model.id
            s.marker.value?.zIndex = type == .start ? Int32(MapOverlayZIndex.startMarkerOverlay.rawValue) : Int32(MapOverlayZIndex.endMarkerOverlay.rawValue)
            views.append(s)
        }
    }

    private func createCameraUpdate(for bounds: GMSCoordinateBounds, with insets: UIEdgeInsets) -> GMSCameraUpdate {
        GMSCameraUpdate.fit(bounds, with: insets)
    }

    private func createCameraPosition(for target: CLLocationCoordinate2D, zoom: Float, bearing: Double, tilt: Float) -> GMSCameraPosition {
        GMSCameraPosition(target: target, zoom: zoom, bearing: CLLocationDirection(floatLiteral: bearing), viewingAngle: Double(tilt))
    }

}

private enum MarkerType: String {
    case start = "start_marker"
    case end = "end_marker"
    case stop
}
