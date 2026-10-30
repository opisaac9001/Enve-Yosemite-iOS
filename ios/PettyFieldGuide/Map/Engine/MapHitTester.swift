import CoreGraphics

enum MapHit: Equatable {
    case marker(id: String)
    case cluster(ids: [String], screenPoint: CGPoint)
    case building(id: String)
    case parking(id: String)
    case trail(id: String)
    case route(id: String)
    case road(id: String)
    case fireScar(id: String)
    case overlayArea(id: String)
    case overlayLine(id: String)
    case none
}

enum MapHitTester {
    /// Markers resolve against the same `MarkerLayout` the renderer drew; base geometry only counts
    /// when the renderer's visibility rules draw it at this zoom with these options.
    static func hit(at screen: CGPoint, scene: MapScene?, camera: MapCamera, content: MapFrameContent, options: MapFrameOptions) -> MapHit {
        let layout = MarkerLayout.compute(content.markers, camera: camera, elementScale: options.elementScale, selectedId: content.selectedMarkerId)
        if let item = MarkerLayout.hit(layout, at: screen, slack: 6 * options.elementScale) {
            return item.isCluster ? .cluster(ids: item.members.map(\.id), screenPoint: item.anchor) : .marker(id: item.representative.id)
        }
        let projected = camera.projectedPoint(for: screen)
        let lineTolerance = 14 / camera.scale
        // The highlighted hike is drawn above every geometry overlay, so it wins before shuttle shapes and plumes at any zoom.
        if let id = options.highlightedRouteId, let route = scene?.hikeRoutes[id],
           route.bounds.insetBy(dx: -lineTolerance, dy: -lineTolerance).contains(projected),
           GeometryOps.distance(projected, toPolyline: route.points) <= lineTolerance {
            return .route(id: id)
        }
        var bestOverlay: (String, CGFloat)?
        for line in content.overlayLines where GeometryOps.bounds(of: line.points).insetBy(dx: -lineTolerance, dy: -lineTolerance).contains(projected) {
            let d = GeometryOps.distance(projected, toPolyline: line.points)
            if d <= lineTolerance && (bestOverlay == nil || d < bestOverlay!.1) { bestOverlay = (line.id, d) }
        }
        if let (id, _) = bestOverlay { return .overlayLine(id: id) }
        for area in content.overlayAreas {
            if let outer = area.rings.first, GeometryOps.pointInRing(projected, outer) { return .overlayArea(id: area.id) }
        }
        guard let scene else { return .none }
        let scale = camera.scale
        if MapRenderer.buildingsVisible(options, scale: scale) {
            for b in scene.buildings where b.contains(projected) { return .building(id: b.id) }
        }
        if MapRenderer.parkingVisible(scale: scale) {
            for p in scene.parking where p.contains(projected) { return .parking(id: p.id) }
        }
        let probe = CGRect(x: projected.x - lineTolerance, y: projected.y - lineTolerance, width: lineTolerance * 2, height: lineTolerance * 2)
        var bestLine: (String, CGFloat, Bool)?
        for tr in scene.trails where tr.bounds.intersects(probe) && MapRenderer.trailVisible(tr, scale: scale) {
            let d = GeometryOps.distance(projected, toPolyline: tr.points)
            if d <= lineTolerance && (bestLine == nil || d < bestLine!.1) { bestLine = (tr.id, d, true) }
        }
        for r in scene.roads where r.bounds.intersects(probe) && MapRenderer.roadVisible(r.styleKey, scale: scale) {
            let d = GeometryOps.distance(projected, toPolyline: r.points)
            if d <= lineTolerance && (bestLine == nil || d < bestLine!.1) { bestLine = (r.id, d, false) }
        }
        if let (id, _, isTrail) = bestLine { return isTrail ? .trail(id: id) : .road(id: id) }
        for scar in scene.fireScars where scar.contains(projected) { return .fireScar(id: scar.id) }
        return .none
    }
}
