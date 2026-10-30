import SwiftUI
import UIKit

struct HikeTerrainInspector: View {
    let inspector: HikeInspector
    @Binding var metres: Double?
    var chartHeight: CGFloat = 150
    /// Fixed readout line counts keep a bounded card's height constant while scrubbing; off, values wrap in full.
    var reservesReadoutSpace = false
    var onCenter: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var inspection: HikeInspection? { metres.map(inspector.inspection(at:)) }
    private var large: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HikeProfileChart(inspector: inspector, metres: $metres, height: chartHeight)
            units
            readout
            controls
        }
    }

    private var units: some View {
        let profile = inspector.profile
        return HStack(alignment: .firstTextBaseline) {
            Text("ft · miles along the mapped route, in travel order").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("Low \(HikeFormat.feet(metres: profile.minMetres)) · high \(HikeFormat.feet(metres: profile.maxMetres))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var readout: some View {
        let headline = Text(inspection?.headline ?? "Tap or drag the chart, or choose a landmark").font(.fieldCaption.weight(.semibold)).monospacedDigit()
        let landmark = Text(inspection?.landmarkText ?? "Distance, terrain elevation and grade are approximate.").font(.caption2).foregroundStyle(.secondary)
        return VStack(alignment: .leading, spacing: 2) {
            if reservesReadoutSpace {
                headline.lineLimit(large ? 3 : 1, reservesSpace: large).minimumScaleFactor(large ? 1 : 0.8)
                landmark.lineLimit(large ? 3 : 2, reservesSpace: true)
            } else {
                headline
                landmark
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        let previous = inspector.previousLandmark(before: metres)
        let next = inspector.nextLandmark(after: metres)
        return layout {
            Button { if let previous { metres = previous.metres } } label: { Image(systemName: "chevron.backward").frame(minWidth: 32, minHeight: 44) }
                .disabled(previous == nil)
                .accessibilityLabel(previous.map { "Previous landmark, \($0.displayName)" } ?? "Previous landmark")
            Menu {
                ForEach(inspector.landmarks) { landmark in
                    Button { metres = landmark.metres } label: {
                        if inspection?.at?.id == landmark.id { Label(menuTitle(landmark), systemImage: "checkmark") } else { Text(menuTitle(landmark)) }
                    }
                }
            } label: {
                Label(inspection?.at?.displayName ?? "Landmarks", systemImage: "mappin.and.ellipse").lineLimit(large ? 3 : 1).frame(minHeight: 44)
            }
            .accessibilityLabel(inspection?.at.map { "Landmarks, at \($0.displayName)" } ?? "Landmarks")
            Button { if let next { metres = next.metres } } label: { Image(systemName: "chevron.forward").frame(minWidth: 32, minHeight: 44) }
                .disabled(next == nil)
                .accessibilityLabel(next.map { "Next landmark, \($0.displayName)" } ?? "Next landmark")
            if !large { Spacer(minLength: 0) }
            if let onCenter {
                Button(action: onCenter) { Label("Center", systemImage: "scope").frame(minHeight: 44) }
                    .disabled(metres == nil)
                    .accessibilityLabel("Center the map on the inspected point")
            }
        }
        .buttonStyle(.bordered).font(.fieldCaption)
    }

    private func menuTitle(_ landmark: HikeLandmark) -> String {
        "\(landmark.displayName) · \(HikeFormat.inspectionMiles(landmark.metres))"
    }
}

/// Profile canvas with landmark ticks, out/back halves and the cursor; one VoiceOver element with an adjustable action.
struct HikeProfileChart: View {
    let inspector: HikeInspector
    @Binding var metres: Double?
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme

    static let plotInsets = UIEdgeInsets(top: 12, left: 44, bottom: 18, right: 8)

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: plotInsets.left, y: plotInsets.top, width: max(1, size.width - plotInsets.left - plotInsets.right),
               height: max(1, size.height - plotInsets.top - plotInsets.bottom))
    }

    static func metres(forX x: CGFloat, width: CGFloat, total: Double) -> Double {
        let plot = plotRect(in: CGSize(width: width, height: 100))
        return Double(min(max((x - plot.minX) / plot.width, 0), 1)) * total
    }

    var body: some View {
        Canvas { ctx, size in draw(ctx, size) }
            .frame(height: height)
            .overlay { HikeProfileScrubber { x, width in metres = Self.metres(forX: x, width: width, total: inspector.totalMetres) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
            .accessibilityValue(metres.map { inspector.inspection(at: $0).accessibilitySummary } ?? "No point selected")
            .accessibilityHint("Swipe up or down to move along the route")
            .accessibilityAdjustableAction { direction in metres = inspector.step(from: metres, forward: direction == .increment) }
    }

    private var summary: String {
        let p = inspector.profile
        let first = Int(p.samples.first!.elevationMetres * 3.28084), last = Int(p.samples.last!.elevationMetres * 3.28084)
        return "Terrain profile in travel order. Starts about \(first) feet, high point \(Int(p.maxMetres * 3.28084)) feet, low point \(Int(p.minMetres * 3.28084)) feet, ends about \(last) feet. Terrain-sampled climb roughly \(Int(p.approxGainMetres * 3.28084)) feet, which is an approximation and not the NPS gain figure."
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let profile = inspector.profile
        let plot = Self.plotRect(in: size)
        let minFt = profile.minMetres * 3.28084, maxFt = profile.maxMetres * 3.28084
        let floor = (minFt / 100).rounded(.down) * 100
        let ceiling = max((maxFt / 100).rounded(.up) * 100, floor + 100)
        let total = max(inspector.totalMetres, 1)
        func x(_ metres: Double) -> CGFloat { plot.minX + plot.width * CGFloat(metres / total) }
        func y(_ feet: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((feet - floor) / (ceiling - floor)) }

        var grid = Path()
        let step: Double = ceiling - floor > 2000 ? 1000 : ceiling - floor > 800 ? 500 : 100
        var level = floor
        while level <= ceiling + 0.1 {
            grid.move(to: CGPoint(x: plot.minX, y: y(level))); grid.addLine(to: CGPoint(x: plot.maxX, y: y(level)))
            ctx.draw(Text("\(Int(level))").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 4, y: y(level)), anchor: .trailing)
            level += step
        }
        ctx.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)

        var area = Path()
        area.move(to: CGPoint(x: x(0), y: plot.maxY))
        for s in profile.samples { area.addLine(to: CGPoint(x: x(s.distanceMetres), y: y(s.elevationMetres * 3.28084))) }
        area.addLine(to: CGPoint(x: x(profile.totalMetres), y: plot.maxY))
        area.closeSubpath()
        ctx.fill(area, with: .color(Palette.accent.opacity(scheme == .dark ? 0.25 : 0.18)))
        var line = Path()
        for (i, s) in profile.samples.enumerated() {
            let p = CGPoint(x: x(s.distanceMetres), y: y(s.elevationMetres * 3.28084))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.stroke(line, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        if inspector.kind == .outAndBack {
            let turn = x(inspector.turnaroundMetres)
            ctx.fill(Path(CGRect(x: turn, y: plot.minY, width: plot.maxX - turn, height: plot.height)), with: .color(.secondary.opacity(0.08)))
            var divider = Path()
            divider.move(to: CGPoint(x: turn, y: plot.minY)); divider.addLine(to: CGPoint(x: turn, y: plot.maxY))
            ctx.stroke(divider, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
            ctx.draw(Text("out →").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary), at: CGPoint(x: (plot.minX + turn) / 2, y: plot.minY - 5))
            ctx.draw(Text("← back").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary), at: CGPoint(x: (turn + plot.maxX) / 2, y: plot.minY - 5))
        }
        for landmark in inspector.landmarks where landmark.metres > 0 && landmark.metres < inspector.totalMetres && landmark.metres != inspector.turnaroundMetres {
            var tick = Path()
            tick.move(to: CGPoint(x: x(landmark.metres), y: plot.minY)); tick.addLine(to: CGPoint(x: x(landmark.metres), y: plot.maxY))
            ctx.stroke(tick, with: .color(Palette.river.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        let milesTotal = profile.totalMetres / 1609.344
        let labelStep: Double = milesTotal > 10 ? 2 : milesTotal > 4 ? 1 : 0.5
        var mile = 0.0
        while mile <= milesTotal + 0.01 {
            ctx.draw(Text(mile == mile.rounded() ? "\(Int(mile))" : String(format: "%.1f", mile)).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: x(mile * 1609.344), y: plot.maxY + 9))
            mile += labelStep
        }

        if let metres {
            let cx = x(min(max(metres, 0), inspector.totalMetres))
            let cy = y(inspector.elevation(at: metres) * 3.28084)
            var cursor = Path()
            cursor.move(to: CGPoint(x: cx, y: plot.minY)); cursor.addLine(to: CGPoint(x: cx, y: plot.maxY))
            ctx.stroke(cursor, with: .color(.primary.opacity(0.65)), lineWidth: 1)
            let dot = Path(ellipseIn: CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10))
            ctx.fill(dot, with: .color(Palette.accent))
            ctx.stroke(dot, with: .color(.white), lineWidth: 1.5)
        }
    }
}

/// Transparent UIKit layer over the chart; a drag more vertical than horizontal is refused so the page keeps scrolling.
struct HikeProfileScrubber: UIViewRepresentable {
    let onScrub: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> ScrubView {
        let view = ScrubView(frame: .zero)
        view.onScrub = onScrub
        return view
    }

    func updateUIView(_ view: ScrubView, context: Context) { view.onScrub = onScrub }

    final class ScrubView: UIView, UIGestureRecognizerDelegate {
        var onScrub: ((CGFloat, CGFloat) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
            for g in [pan, tap, hover] { addGestureRecognizer(g) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        static func beginsPan(velocity: CGPoint) -> Bool { abs(velocity.x) > abs(velocity.y) }

        override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            return Self.beginsPan(velocity: pan.velocity(in: self))
        }

        func scrub(x: CGFloat) { onScrub?(x, bounds.width) }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began, .changed, .ended: scrub(x: g.location(in: self).x)
            default: break
            }
        }

        @objc private func handleTap(_ g: UITapGestureRecognizer) { scrub(x: g.location(in: self).x) }

        @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
            guard g.state == .began || g.state == .changed else { return }
            scrub(x: g.location(in: self).x)
        }
    }
}
