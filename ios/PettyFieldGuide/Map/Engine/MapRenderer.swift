import UIKit
import CoreGraphics

/// Per-frame rendering inputs that are not part of the static scene.
struct MapFrameOptions {
    var dark: Bool
    var elementScale: CGFloat = 1
    var showBuildings = true
    var buildingLabelMode: BuildingLabelMode = .callouts
    var showContours = false
    var emphasizeShuttle = false
    var showRoadNames = true
    var showOneWayArrows = true
    /// Resolved hike route drawn above the base trails whatever the zoom or trail filters.
    var highlightedRouteId: String?
    var dimBase = false
    /// Secondary maps keep the in-canvas bar; the Valley map draws its own above the chrome.
    var showsScaleBar = true
    /// Screen edges covered by chrome; labels are never placed there.
    var obscuredInsets: UIEdgeInsets = .zero
}

enum BuildingLabelMode: String, CaseIterable, Codable, Identifiable {
    case callouts, footprint, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .callouts: "Callouts"
        case .footprint: "On footprint"
        case .off: "Off"
        }
    }
}

/// Extra geometry drawn above the base scene (routes, highlights, overlays).
struct MapOverlayLine: Sendable {
    let id: String
    let points: [CGPoint]
    let colorHex: String
    let width: CGFloat
    let dashed: Bool
    let directional: Bool
}

struct MapOverlayArea: Sendable {
    let id: String
    let rings: [[CGPoint]]
    let fillHex: String
    let fillAlpha: CGFloat
    let strokeHex: String?
    let title: String?
}

struct MapOverlayImage: @unchecked Sendable {
    let image: CGImage
    let rect: CGRect              // projected metres
    let alpha: CGFloat
}

struct MapTextLabel: Sendable {
    let point: CGPoint
    let text: String
    let size: CGFloat
    let colorHex: String
    let halo: Bool
    let priority: Int
    var kind: LabelKind = .landform
}

struct MapFrameContent {
    var markers: [MapMarker] = []
    var overlayAreas: [MapOverlayArea] = []
    var overlayLines: [MapOverlayLine] = []
    var overlayImages: [MapOverlayImage] = []
    var labels: [MapTextLabel] = []
    var selectedMarkerId: String?
    /// Projected point being inspected on the highlighted route; drawn above everything, never a tap target.
    var routeCursor: CGPoint?
}

enum MapRenderer {
    struct Style {
        var land: UIColor
        var waterArea: UIColor
        var river: UIColor
        var stream: UIColor
        var building: UIColor
        var buildingStroke: UIColor
        var buildingClosed: UIColor
        var parking: UIColor
        var parkingStroke: UIColor
        var roadCasing: UIColor
        var serviceCasing: UIColor
        var roadSecondary: UIColor
        var roadLocal: UIColor
        var roadService: UIColor
        var trail: UIColor
        var bike: UIColor
        var contour: UIColor
        var text: UIColor
        var roadText: UIColor
        var landformText: UIColor
        var waterText: UIColor
        var buildingText: UIColor
        var halo: UIColor

        static func make(dark: Bool) -> Style {
            if dark {
                return Style(land: UIColor(red: 0.125, green: 0.145, blue: 0.165, alpha: 1),
                             waterArea: UIColor(red: 0.14, green: 0.28, blue: 0.40, alpha: 1),
                             river: UIColor(red: 0.38, green: 0.62, blue: 0.82, alpha: 1),
                             stream: UIColor(red: 0.30, green: 0.50, blue: 0.68, alpha: 1),
                             building: UIColor(red: 0.31, green: 0.32, blue: 0.33, alpha: 1),
                             buildingStroke: UIColor(red: 0.46, green: 0.47, blue: 0.48, alpha: 1),
                             buildingClosed: UIColor(red: 0.22, green: 0.23, blue: 0.24, alpha: 1),
                             parking: UIColor(red: 0.21, green: 0.22, blue: 0.24, alpha: 0.95),
                             parkingStroke: UIColor(red: 0.33, green: 0.34, blue: 0.36, alpha: 1),
                             roadCasing: UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1),
                             serviceCasing: UIColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1),
                             roadSecondary: UIColor(red: 0.82, green: 0.82, blue: 0.80, alpha: 1),
                             roadLocal: UIColor(red: 0.63, green: 0.63, blue: 0.61, alpha: 1),
                             roadService: UIColor(red: 0.40, green: 0.41, blue: 0.42, alpha: 1),
                             trail: UIColor(red: 0.84, green: 0.62, blue: 0.42, alpha: 0.95),
                             bike: UIColor(red: 0.42, green: 0.76, blue: 0.62, alpha: 1),
                             contour: UIColor(white: 0.62, alpha: 0.32),
                             text: UIColor(red: 0.94, green: 0.93, blue: 0.89, alpha: 1),
                             roadText: UIColor(red: 0.90, green: 0.89, blue: 0.86, alpha: 1),
                             landformText: UIColor(red: 0.88, green: 0.86, blue: 0.80, alpha: 1),
                             waterText: UIColor(red: 0.62, green: 0.80, blue: 0.94, alpha: 1),
                             buildingText: UIColor(red: 0.84, green: 0.83, blue: 0.80, alpha: 1),
                             halo: UIColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 0.82))
            }
            return Style(land: UIColor(red: 0.90, green: 0.88, blue: 0.81, alpha: 1),
                         waterArea: UIColor(red: 0.68, green: 0.80, blue: 0.88, alpha: 1),
                         river: UIColor(red: 0.27, green: 0.50, blue: 0.71, alpha: 1),
                         stream: UIColor(red: 0.40, green: 0.60, blue: 0.77, alpha: 1),
                         building: UIColor(red: 0.74, green: 0.67, blue: 0.58, alpha: 0.96),
                         buildingStroke: UIColor(red: 0.55, green: 0.47, blue: 0.39, alpha: 1),
                         buildingClosed: UIColor(red: 0.78, green: 0.76, blue: 0.72, alpha: 0.9),
                         parking: UIColor(red: 0.80, green: 0.78, blue: 0.74, alpha: 0.9),
                         parkingStroke: UIColor(red: 0.64, green: 0.62, blue: 0.58, alpha: 1),
                         roadCasing: UIColor(red: 0.46, green: 0.43, blue: 0.39, alpha: 1),
                         serviceCasing: UIColor(red: 0.64, green: 0.62, blue: 0.58, alpha: 1),
                         roadSecondary: UIColor(red: 1.0, green: 0.99, blue: 0.96, alpha: 1),
                         roadLocal: UIColor(red: 0.985, green: 0.975, blue: 0.95, alpha: 1),
                         roadService: UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1),
                         trail: UIColor(red: 0.55, green: 0.30, blue: 0.16, alpha: 0.9),
                         bike: UIColor(red: 0.12, green: 0.47, blue: 0.42, alpha: 1),
                         contour: UIColor(red: 0.50, green: 0.40, blue: 0.26, alpha: 0.4),
                         text: UIColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1),
                         roadText: UIColor(red: 0.26, green: 0.24, blue: 0.21, alpha: 1),
                         landformText: UIColor(red: 0.31, green: 0.28, blue: 0.23, alpha: 1),
                         waterText: UIColor(red: 0.18, green: 0.38, blue: 0.58, alpha: 1),
                         buildingText: UIColor(red: 0.30, green: 0.27, blue: 0.23, alpha: 1),
                         halo: UIColor(red: 1.0, green: 0.99, blue: 0.96, alpha: 0.85))
        }
    }

    private static let accent = UIColor(hex: "#F5921A")

    private static let roadRank: [String: Int] = ["road-service": 0, "road-private": 0, "road-parking": 1, "road-local": 2, "road-secondary": 3]

    // Visibility rules are shared with MapHitTester so hidden geometry never intercepts taps.
    static func parkingVisible(scale: CGFloat) -> Bool { scale >= 0.06 }
    static func buildingsVisible(_ options: MapFrameOptions, scale: CGFloat) -> Bool { options.showBuildings && scale >= 0.1 }

    static func roadVisible(_ key: String, scale: CGFloat) -> Bool {
        switch key {
        case "road-service": scale >= 0.07
        case "road-private": scale >= 0.15
        case "road-parking": scale >= 0.1
        default: true
        }
    }

    private static func roadWidth(_ key: String, scale: CGFloat, elementScale es: CGFloat) -> (fill: CGFloat, casing: CGFloat) {
        let grow = min(2.2, max(0.55, 0.55 + scale * 1.5))
        let (base, casing): (CGFloat, CGFloat) = switch key {
        case "road-secondary": (5.5, 1.8)
        case "road-local": (3.8, 1.6)
        case "road-parking": (2.4, 1.0)
        default: (2.0, 1.0)
        }
        return (base * grow * es, casing * es)
    }

    static func trailVisible(_ trail: LineFeature, scale: CGFloat) -> Bool {
        if trail.styleKey == "bike" { return scale >= 0.03 }
        guard let name = trail.name, !name.isEmpty else { return scale >= 0.15 }
        if scale >= 0.08 { return true }
        guard scale >= 0.035 else { return false }
        let minor = ["Path", "Footpath", "Boardwalk", "Loop Road", "Access", "Camp 4"]
        return !minor.contains { name.contains($0) }
    }

    static func draw(scene: MapScene?, camera: MapCamera, options: MapFrameOptions, content: MapFrameContent, in ctx: CGContext) {
        let style = Style.make(dark: options.dark)
        let viewRect = CGRect(origin: .zero, size: camera.viewSize)
        ctx.setFillColor(style.land.cgColor)
        ctx.fill(viewRect)
        guard let scene else { return }
        let lod = LevelOfDetail.forScale(camera.scale)
        let visible = camera.visibleRect(margin: 40)
        let t = camera.transform
        let es = options.elementScale
        let scale = camera.scale

        for tier in scene.relief?.tiers ?? [] where tier.rect.intersects(visible) {
            drawImage(tier.image(dark: options.dark), in: tier.rect, alpha: 1, camera: camera, ctx: ctx)
        }

        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        for area in scene.waterAreas where area.bounds.intersects(visible) {
            addPath(area.path(lod), transform: t, to: ctx)
            ctx.setFillColor(style.waterArea.cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        let riverWidth = min(7, 1.6 + scale * 5) * es
        let streamWidth = min(3.5, 0.9 + scale * 2.5) * es
        for line in scene.waterLines where line.bounds.intersects(visible) {
            let major = line.styleKey == "river"
            addPath(line.path(lod), transform: t, to: ctx)
            ctx.setStrokeColor((major ? style.river : style.stream).cgColor)
            ctx.setLineWidth(major ? riverWidth : streamWidth)
            ctx.strokePath()
        }

        if options.showContours {
            for c in scene.contours where c.bounds.intersects(visible) {
                addPath(c.path(lod), transform: t, to: ctx)
                ctx.setStrokeColor(style.contour.cgColor)
                ctx.setLineWidth(c.styleKey == "contour-index" ? 1.1 : 0.55)
                ctx.strokePath()
            }
        }

        if parkingVisible(scale: scale) {
            for p in scene.parking where p.bounds.intersects(visible) {
                addPath(p.path(lod), transform: t, to: ctx)
                ctx.setFillColor(style.parking.cgColor)
                ctx.setStrokeColor(style.parkingStroke.cgColor)
                ctx.setLineWidth(scale >= 0.3 ? 0.7 : 0.4)
                ctx.drawPath(using: .eoFillStroke)
            }
        }
        if buildingsVisible(options, scale: scale) {
            for b in scene.buildings where b.bounds.intersects(visible) {
                addPath(b.path(lod), transform: t, to: ctx)
                ctx.setFillColor((b.styleKey == "building" ? style.building : style.buildingClosed).cgColor)
                ctx.setStrokeColor(style.buildingStroke.cgColor)
                ctx.setLineWidth(scale >= 0.5 ? 0.8 : 0.4)
                ctx.drawPath(using: .eoFillStroke)
            }
        }

        // Roads: every casing first, then fills from minor to major so junctions resolve cleanly.
        let visibleRoads = scene.roads
            .filter { $0.bounds.intersects(visible) && roadVisible($0.styleKey, scale: scale) }
            .sorted { (roadRank[$0.styleKey] ?? 1) < (roadRank[$1.styleKey] ?? 1) }
        for r in visibleRoads {
            let w = roadWidth(r.styleKey, scale: scale, elementScale: es)
            addPath(r.path(lod), transform: t, to: ctx)
            ctx.setStrokeColor(((roadRank[r.styleKey] ?? 1) <= 1 ? style.serviceCasing : style.roadCasing).cgColor)
            ctx.setLineWidth(w.fill + w.casing)
            ctx.strokePath()
        }
        for r in visibleRoads {
            let w = roadWidth(r.styleKey, scale: scale, elementScale: es)
            let fill: UIColor = switch r.styleKey {
            case "road-secondary": style.roadSecondary
            case "road-local": style.roadLocal
            default: style.roadService
            }
            addPath(r.path(lod), transform: t, to: ctx)
            ctx.setStrokeColor(fill.cgColor)
            ctx.setLineWidth(w.fill)
            ctx.setLineDash(phase: 0, lengths: r.seasonal != nil ? [8, 4] : [])
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])

        let trailWidth = min(2.0, max(1.0, 0.9 + scale * 1.2)) * es
        for tr in scene.trails where tr.bounds.intersects(visible) && trailVisible(tr, scale: scale) {
            addPath(tr.path(lod), transform: t, to: ctx)
            if tr.styleKey == "bike" {
                ctx.setStrokeColor(style.bike.cgColor)
                ctx.setLineWidth(trailWidth * 1.3)
                ctx.setLineDash(phase: 0, lengths: [])
            } else {
                ctx.setStrokeColor(style.trail.cgColor)
                ctx.setLineWidth(trailWidth)
                ctx.setLineDash(phase: 0, lengths: [4.5 * es, 3.5 * es])
            }
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])

        if options.showOneWayArrows && scale >= 0.35 {
            for r in visibleRoads where r.oneWay != 0 {
                drawArrows(along: r.points, direction: r.oneWay, camera: camera, color: style.roadText.withAlphaComponent(0.75), ctx: ctx, spacing: 90 / scale)
            }
        }

        for scar in scene.fireScars where scar.bounds.intersects(visible) {
            addPath(scar.path(lod), transform: t, to: ctx)
            ctx.setFillColor(UIColor(red: 0.85, green: 0.35, blue: 0.2, alpha: options.dark ? 0.22 : 0.16).cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        for b in scene.boundary where b.bounds.intersects(visible) {
            addPath(b.path(lod), transform: t, to: ctx)
            ctx.setStrokeColor(UIColor(hex: "#1F4D3F").withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [10, 5])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if options.dimBase {
            ctx.setFillColor(UIColor.black.withAlphaComponent(options.dark ? 0.35 : 0.12).cgColor)
            ctx.fill(viewRect)
        }

        for img in content.overlayImages where img.rect.intersects(visible) {
            drawImage(img.image, in: img.rect, alpha: img.alpha, camera: camera, ctx: ctx)
        }
        for area in content.overlayAreas {
            let path = CGMutablePath()
            for ring in area.rings where ring.count > 2 {
                path.addLines(between: ring)
                path.closeSubpath()
            }
            guard path.boundingBoxOfPath.intersects(visible) else { continue }
            addPath(path, transform: t, to: ctx)
            ctx.setFillColor(UIColor(hex: area.fillHex).withAlphaComponent(area.fillAlpha).cgColor)
            ctx.fillPath(using: .evenOdd)
            if let stroke = area.strokeHex {
                addPath(path, transform: t, to: ctx)
                ctx.setStrokeColor(UIColor(hex: stroke).cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
            }
        }
        let routeBoost: CGFloat = options.emphasizeShuttle ? 1.7 : 1
        for line in content.overlayLines where GeometryOps.bounds(of: line.points).intersects(visible) {
            let path = CGMutablePath()
            path.addLines(between: line.points)
            if options.emphasizeShuttle {
                addPath(path, transform: t, to: ctx)
                ctx.setStrokeColor(style.halo.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(line.width * es * routeBoost + 2)
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.strokePath()
            }
            addPath(path, transform: t, to: ctx)
            ctx.setStrokeColor(UIColor(hex: line.colorHex).withAlphaComponent(options.emphasizeShuttle ? 1 : 0.9).cgColor)
            ctx.setLineWidth(line.width * es * routeBoost)
            ctx.setLineDash(phase: 0, lengths: line.dashed ? [10, 6] : [])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            if line.directional && scale >= 0.3 {
                drawArrows(along: line.points, direction: 1, camera: camera, color: UIColor(hex: line.colorHex), ctx: ctx, spacing: 160 / scale)
            }
        }
        // The selected hike sits above every geometry overlay (shuttle shapes, plumes, sun raster) and below labels and markers.
        if let id = options.highlightedRouteId, let route = scene.hikeRoutes[id], route.bounds.intersects(visible) {
            drawRoute(route, lod: lod, transform: t, elementScale: es, dark: options.dark, ctx: ctx)
        }
        ctx.restoreGState()

        let layout = MarkerLayout.compute(content.markers, camera: camera, elementScale: es, selectedId: content.selectedMarkerId)
        drawLabels(scene: scene, camera: camera, options: options, content: content, layout: layout, visibleRoads: visibleRoads, style: style, ctx: ctx)
        for item in layout { drawMarker(item, selectedId: content.selectedMarkerId, style: style, elementScale: es, ctx: ctx) }
        if let cursor = content.routeCursor, visible.contains(cursor) {
            drawRouteCursor(at: camera.screenPoint(for: cursor), elementScale: es, ctx: ctx)
        }

        if options.showsScaleBar { drawScaleBar(camera: camera, style: style, ctx: ctx) }
    }

    private static func drawRouteCursor(at p: CGPoint, elementScale es: CGFloat, ctx: CGContext) {
        let r = 7 * es
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r - 2.5, y: p.y - r - 2.5, width: (r + 2.5) * 2, height: (r + 2.5) * 2))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setFillColor(accent.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4))
        ctx.restoreGState()
    }

    static let routeCasing = UIColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1)

    /// Cream-cased orange stroke for the selected hike, simplified like the base trails but never culled.
    private static func drawRoute(_ route: MapRouteTrace, lod: LevelOfDetail, transform: CGAffineTransform, elementScale es: CGFloat, dark: Bool, ctx: CGContext) {
        let path = route.path(lod)
        ctx.setLineDash(phase: 0, lengths: [])
        addPath(path, transform: transform, to: ctx)
        ctx.setStrokeColor((dark ? UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 0.9) : routeCasing).cgColor)
        ctx.setLineWidth(9 * es)
        ctx.strokePath()
        addPath(path, transform: transform, to: ctx)
        ctx.setStrokeColor(routeCasing.cgColor)
        ctx.setLineWidth(6.5 * es)
        ctx.strokePath()
        addPath(path, transform: transform, to: ctx)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(3.6 * es)
        ctx.strokePath()
    }

    private static func addPath(_ path: CGPath, transform: CGAffineTransform, to ctx: CGContext) {
        var tf = transform
        if let transformed = path.copy(using: &tf) { ctx.addPath(transformed) }
    }

    // Row 0 of the raster is the north edge of `rect` (projected metres).
    private static func drawImage(_ image: CGImage, in rect: CGRect, alpha: CGFloat, camera: MapCamera, ctx: CGContext) {
        let a = camera.screenPoint(for: CGPoint(x: rect.minX, y: rect.maxY))
        let b = camera.screenPoint(for: CGPoint(x: rect.maxX, y: rect.minY))
        let screen = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: screen.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: screen.minX, y: 0, width: screen.width, height: screen.height))
        ctx.restoreGState()
    }

    private static func drawArrows(along points: [CGPoint], direction: Int, camera: MapCamera, color: UIColor, ctx: CGContext, spacing: CGFloat) {
        guard points.count > 1 else { return }
        let pts = direction < 0 ? Array(points.reversed()) : points
        var distanceToNext = spacing / 2
        ctx.setFillColor(color.cgColor)
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let segLen = hypot(b.x - a.x, b.y - a.y)
            guard segLen > 0 else { continue }
            var along = distanceToNext
            while along < segLen {
                let tpos = along / segLen
                let p = camera.screenPoint(for: CGPoint(x: a.x + (b.x - a.x) * tpos, y: a.y + (b.y - a.y) * tpos))
                let angle = atan2(-(b.y - a.y), b.x - a.x)
                let size: CGFloat = 5
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                ctx.rotate(by: angle)
                ctx.move(to: CGPoint(x: size, y: 0))
                ctx.addLine(to: CGPoint(x: -size * 0.8, y: size * 0.7))
                ctx.addLine(to: CGPoint(x: -size * 0.8, y: -size * 0.7))
                ctx.closePath()
                ctx.fillPath()
                ctx.restoreGState()
                along += spacing
            }
            distanceToNext = along - segLen
        }
    }

    private struct StyledLabel {
        let font: UIFont
        let color: UIColor
        let halo: UIColor?
        let maxWidth: CGFloat?
    }

    static func font(for kind: LabelKind, size: CGFloat) -> UIFont {
        switch kind {
        case .landform, .water:
            let base = UIFont.systemFont(ofSize: size, weight: kind == .water ? .medium : .semibold)
            if let d = base.fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.traitItalic) { return UIFont(descriptor: d, size: size) }
            return base
        case .road: return UIFont.systemFont(ofSize: size, weight: .semibold)
        case .place: return UIFont.systemFont(ofSize: size, weight: .semibold)
        case .building: return UIFont.systemFont(ofSize: size, weight: .medium)
        case .custom: return UIFont.systemFont(ofSize: size, weight: .bold)
        }
    }

    private static func measure(_ text: String, font: UIFont, maxWidth: CGFloat?) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        guard let maxWidth else { return (text as NSString).size(withAttributes: attrs) }
        let r = (text as NSString).boundingRect(with: CGSize(width: maxWidth, height: 80), options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Screen point and reading angle at the arc-length midpoint of a projected polyline.
    static func lineLabelAnchor(_ points: [CGPoint], camera: MapCamera) -> (point: CGPoint, angle: CGFloat)? {
        guard points.count > 1 else { return nil }
        let total = GeometryOps.length(points)
        guard total > 0 else { return nil }
        var remaining = total / 2
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let seg = hypot(b.x - a.x, b.y - a.y)
            if remaining <= seg || i == points.count - 1 {
                let f = seg > 0 ? min(1, remaining / seg) : 0
                let p = camera.screenPoint(for: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                var angle = atan2(-(b.y - a.y), b.x - a.x)
                if angle > .pi / 2 { angle -= .pi }
                if angle < -.pi / 2 { angle += .pi }
                return (p, angle)
            }
            remaining -= seg
        }
        return nil
    }

    private static func drawLabels(scene: MapScene, camera: MapCamera, options: MapFrameOptions, content: MapFrameContent, layout: [PlacedMarker],
                                   visibleRoads: [LineFeature], style: Style, ctx: CGContext) {
        let es = options.elementScale
        let scale = camera.scale
        let visible = camera.visibleRect(margin: 40)
        var candidates: [LabelCandidate] = []
        var styles: [String: StyledLabel] = [:]

        func add(id: String, text: String, kind: LabelKind, point: CGPoint, priority: Int, font: UIFont, color: UIColor, halo: UIColor?,
                 angle: CGFloat = 0, maxWidth: CGFloat? = nil, offsets: [CGPoint]? = nil, frame: CGRect? = nil) {
            let size = measure(text, font: font, maxWidth: maxWidth)
            let placements = offsets ?? frame.map { LabelPlacer.besideOffsets(frame: $0, anchor: point, size: size) } ?? [.zero]
            candidates.append(LabelCandidate(id: id, text: text, kind: kind, point: point, size: size, priority: priority, angle: angle, offsets: placements))
            styles[id] = StyledLabel(font: font, color: color, halo: halo, maxWidth: maxWidth)
        }

        // At most `perName` of the longest segments per name, drawn along the line.
        func lineLabels(_ features: [LineFeature], minLength: CGFloat, kind: LabelKind, font: UIFont, color: UIColor, prefix: String, perName: Int, priority: (LineFeature) -> Int) {
            var byName: [String: [LineFeature]] = [:]
            for f in features { if let name = f.label ?? f.name, !name.isEmpty { byName[name, default: []].append(f) } }
            for name in byName.keys.sorted() {
                let ranked = byName[name]!.sorted { GeometryOps.length($0.points) != GeometryOps.length($1.points) ? GeometryOps.length($0.points) > GeometryOps.length($1.points) : $0.id < $1.id }
                let width = measure(name, font: font, maxWidth: nil).width
                for f in ranked.prefix(perName) {
                    guard GeometryOps.length(f.points) * scale >= max(minLength, width + 24), let anchor = lineLabelAnchor(f.points, camera: camera) else { continue }
                    add(id: "\(prefix)-\(f.id)", text: name, kind: kind, point: anchor.point, priority: priority(f), font: font, color: color, halo: style.halo, angle: anchor.angle)
                }
            }
        }

        if options.showRoadNames && scale >= 0.1 {
            let roadFont = font(for: .road, size: 10.5 * es)
            lineLabels(visibleRoads.filter { $0.styleKey == "road-secondary" || $0.styleKey == "road-local" || scale >= 0.5 },
                       minLength: 90, kind: .road, font: roadFont, color: style.roadText, prefix: "road", perName: scale >= 0.4 ? 3 : 2) {
                $0.styleKey == "road-secondary" ? 18 : $0.styleKey == "road-local" ? 14 : 10
            }
        }
        if scale >= 0.045 {
            let waterFont = font(for: .water, size: 12 * es)
            let waterLines = scene.waterLines.filter { $0.bounds.intersects(visible) && ($0.styleKey == "river" || scale >= 0.12) }
            lineLabels(waterLines, minLength: 120, kind: .water, font: waterFont, color: style.waterText, prefix: "water", perName: 2) { $0.styleKey == "river" ? 34 : 24 }
        }

        if options.showBuildings && options.buildingLabelMode != .off && scale >= 0.45 {
            let nameFont = font(for: .building, size: (options.buildingLabelMode == .footprint ? 9 : 9.5) * es)
            let named = scene.buildings.filter { $0.bounds.intersects(visible) && !($0.name ?? "").isEmpty }
                .sorted { $0.areaSquareMeters != $1.areaSquareMeters ? $0.areaSquareMeters > $1.areaSquareMeters : $0.id < $1.id }
            for b in named.prefix(scale >= 2 ? 400 : 120) {
                // NPS map labels are often building numbers; show them beside the name at the closest zoom only.
                let numbered = b.label.map { $0 != b.name && Int($0) != nil } ?? false
                let text = scale >= 2 ? (numbered ? "\(b.name!) · \(b.label!)" : b.name!) : (numbered ? b.name! : (b.label ?? b.name!))
                let footprintWide = b.bounds.width * scale > CGFloat(text.count) * 5.5 * es
                if options.buildingLabelMode == .footprint && !footprintWide && scale < 3 { continue }
                add(id: "bld-\(b.id)", text: text, kind: .building, point: camera.screenPoint(for: b.centroid), priority: 6, font: nameFont, color: style.buildingText,
                    halo: style.halo, maxWidth: options.buildingLabelMode == .footprint ? max(40, b.bounds.width * scale) : 120 * es)
            }
        }

        let placeFont = font(for: .place, size: 10.5 * es)
        for item in layout where !item.isCluster {
            let rep = item.representative
            guard let min = rep.labelMinScale, scale >= min else { continue }
            add(id: "mk-\(rep.id)", text: rep.title, kind: .place, point: item.anchor, priority: rep.priority + 20, font: placeFont, color: style.text,
                halo: style.halo, maxWidth: 120 * es, frame: item.frame.insetBy(dx: -1, dy: -1))
        }

        for (i, label) in content.labels.enumerated() where visible.contains(label.point) {
            let f = font(for: label.kind, size: label.size * es)
            add(id: "lbl-\(i)", text: label.text, kind: label.kind, point: camera.screenPoint(for: label.point), priority: label.priority + 40, font: f,
                color: UIColor(hex: label.colorHex), halo: label.halo ? style.halo : nil, offsets: [.zero, CGPoint(x: 0, y: -14 * es), CGPoint(x: 0, y: 14 * es)])
        }

        let bounds = CGRect(origin: .zero, size: camera.viewSize).inset(by: options.obscuredInsets)
        let reserved = layout.map { $0.frame.insetBy(dx: -2, dy: -2) }
        for placed in LabelPlacer.place(candidates, reserved: reserved, bounds: bounds) {
            guard let s = styles[placed.candidate.id] else { continue }
            drawText(placed.candidate.text, at: placed.center, angle: placed.candidate.angle, size: placed.candidate.size, style: s, ctx: ctx)
        }
    }

    private static func drawText(_ text: String, at center: CGPoint, angle: CGFloat, size: CGSize, style: StyledLabel, ctx: CGContext) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: style.color, .paragraphStyle: paragraph]
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        if angle != 0 { ctx.rotate(by: angle) }
        if let halo = style.halo {
            var haloAttrs = attrs
            haloAttrs[.strokeColor] = halo
            haloAttrs[.strokeWidth] = -3.2
            (text as NSString).draw(in: rect, withAttributes: haloAttrs)
        }
        attrs[.strokeWidth] = 0
        (text as NSString).draw(in: rect, withAttributes: attrs)
        ctx.restoreGState()
    }

    nonisolated(unsafe) private static let symbolCache = NSCache<NSString, UIImage>()

    private static func symbolImage(_ name: String, size: CGFloat) -> UIImage? {
        let key = "\(name)-\(size)" as NSString
        if let cached = symbolCache.object(forKey: key) { return cached }
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
        guard let img = UIImage(systemName: name, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        symbolCache.setObject(img, forKey: key)
        return img
    }

    private static func drawMarker(_ item: PlacedMarker, selectedId: String?, style: Style, elementScale es: CGFloat, ctx: CGContext) {
        let rep = item.representative
        let color = UIColor(hex: rep.colorHex)
        let isSelected = item.members.contains { $0.id == selectedId }
        let r = item.radius
        let c = item.center
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: UIColor.black.withAlphaComponent(0.28).cgColor)

        if item.isCluster {
            // Stop clusters keep the stop badge's rounded square; place clusters are round.
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            let path = rep.shape == .stop ? UIBezierPath(roundedRect: rect, cornerRadius: r * 0.42).cgPath : UIBezierPath(ovalIn: rect).cgPath
            ctx.addPath(path)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path)
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
            draw(text: "\(item.count)", at: c, font: UIFont.systemFont(ofSize: r * 0.9, weight: .bold), color: .white)
            if isSelected {
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(2.5)
                ctx.strokeEllipse(in: rect.insetBy(dx: -3.5, dy: -3.5))
            }
            ctx.restoreGState()
            return
        }

        switch rep.shape {
        case .pin, .car, .campsite:
            let tip = item.anchor
            ctx.setFillColor(color.cgColor)
            ctx.move(to: tip)
            ctx.addArc(center: c, radius: r, startAngle: .pi * 0.85, endAngle: .pi * 0.15, clockwise: false)
            ctx.closePath()
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: tip.x - 1.5, y: tip.y - 1.5, width: 3, height: 3))
            drawGlyph(rep, center: c, radius: r, ctx: ctx)
        case .stop:
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: r * 0.42).cgPath
            ctx.addPath(path)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path)
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.3)
            ctx.strokePath()
            drawGlyph(rep, center: c, radius: r, ctx: ctx)
        case .user:
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(color.withAlphaComponent(0.18).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r * 2.4, y: c.y - r * 2.4, width: r * 4.8, height: r * 4.8))
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        case .dot, .badge, .site:
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(rep.shape == .dot ? 1 : 1.2)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            if rep.shape != .dot { drawGlyph(rep, center: c, radius: r, ctx: ctx) }
        }
        if isSelected {
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - r - 3.5, y: c.y - r - 3.5, width: (r + 3.5) * 2, height: (r + 3.5) * 2))
        }
        ctx.restoreGState()
    }

    private static func drawGlyph(_ marker: MapMarker, center c: CGPoint, radius: CGFloat, ctx: CGContext) {
        if let glyph = marker.glyph {
            let font = UIFont.systemFont(ofSize: glyph.count > 2 ? radius * 0.68 : radius * 0.95, weight: .bold)
            draw(text: glyph, at: c, font: font, color: .white)
        } else if let symbol = marker.symbol, let img = symbolImage(symbol, size: radius * 1.0) {
            let size = img.size
            img.draw(in: CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
        }
    }

    private static func draw(text: String, at c: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
    }

    static func scaleBarMetres(for scale: CGFloat, maxWidth: CGFloat = 120) -> CGFloat {
        let candidates: [CGFloat] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
        return candidates.last(where: { $0 * scale <= maxWidth }) ?? candidates[0]
    }

    static func scaleBarText(metres: CGFloat) -> String {
        metres >= 1000 ? String(format: "%.0f km · %.1f mi", metres / 1000, metres / 1609.344) : String(format: "%.0f m · %.0f ft", metres, metres * 3.28084)
    }

    private static func drawScaleBar(camera: MapCamera, style: Style, ctx: CGContext) {
        let metres = scaleBarMetres(for: camera.scale)
        let width = metres * camera.scale
        let origin = CGPoint(x: 16, y: camera.viewSize.height - 18)
        ctx.setStrokeColor(style.text.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: origin)
        ctx.addLine(to: CGPoint(x: origin.x + width, y: origin.y))
        ctx.move(to: origin); ctx.addLine(to: CGPoint(x: origin.x, y: origin.y - 6))
        ctx.move(to: CGPoint(x: origin.x + width, y: origin.y)); ctx.addLine(to: CGPoint(x: origin.x + width, y: origin.y - 6))
        ctx.strokePath()
        let font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        var halo: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.text, .strokeColor: style.halo, .strokeWidth: -3]
        (scaleBarText(metres: metres) as NSString).draw(at: CGPoint(x: origin.x, y: origin.y - 20), withAttributes: halo)
        halo.removeValue(forKey: .strokeColor)
        halo.removeValue(forKey: .strokeWidth)
        (scaleBarText(metres: metres) as NSString).draw(at: CGPoint(x: origin.x, y: origin.y - 20), withAttributes: halo)
    }
}
