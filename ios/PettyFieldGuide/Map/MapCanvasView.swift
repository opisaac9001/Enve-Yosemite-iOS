import SwiftUI
import UIKit

/// UIKit canvas that draws the scene with Core Graphics and owns the pan/pinch/tap recognizers.
final class MapCanvas: UIView, UIGestureRecognizerDelegate {
    var scene: MapScene? { didSet { setNeedsDisplay() } }
    var camera: MapCamera { didSet { if camera != oldValue { setNeedsDisplay() } } }
    var options: MapFrameOptions { didSet { setNeedsDisplay() } }
    var content = MapFrameContent() { didSet { setNeedsDisplay() } }
    var zoomLocked = false
    var scaleLimits: ClosedRange<CGFloat> = 0.005...8
    var clampRect: CGRect?
    var onCameraChange: ((MapCamera) -> Void)?
    var onTap: ((MapHit, CGPoint) -> Void)?
    var onLongPress: ((CGPoint) -> Void)?

    private var pinchStartScale: CGFloat = 1

    init(camera: MapCamera, options: MapFrameOptions) {
        self.camera = camera
        self.options = options
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.5
        for g in [pan, pinch, tap, doubleTap, longPress] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if camera.viewSize != bounds.size {
            camera.viewSize = bounds.size
            onCameraChange?(camera)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        MapRenderer.draw(scene: scene, camera: camera, options: options, content: content, in: ctx)
        rebuildAccessibilityElements()
    }

    /// VoiceOver gets the drawn markers and clusters with the renderer's footprints.
    private func rebuildAccessibilityElements() {
        let layout = MarkerLayout.compute(content.markers, camera: camera, elementScale: options.elementScale, selectedId: content.selectedMarkerId)
        var elements: [MarkerAccessibilityElement] = []
        for item in layout.reversed().prefix(120) {
            let element = MarkerAccessibilityElement(accessibilityContainer: self)
            element.accessibilityFrameInContainerSpace = item.frame.insetBy(dx: -8, dy: -8)
            let rep = item.representative
            let noun = item.members.allSatisfy { $0.shape == .stop } ? "shuttle stops" : "places"
            element.accessibilityLabel = item.isCluster ? "\(item.count) \(noun), including \(rep.accessibleName)" : rep.accessibleName
            element.accessibilityTraits = item.members.contains { $0.id == content.selectedMarkerId } ? [.button, .selected] : .button
            element.accessibilityHint = item.isCluster ? "Activate to zoom in" : "Activate to select"
            // Activate exactly this element, not whatever happens to be topmost at its centre.
            let hit: MapHit = item.isCluster ? .cluster(ids: item.members.map(\.id), screenPoint: item.anchor) : .marker(id: rep.id)
            let point = item.center
            element.activate = { [weak self] in
                guard let self else { return false }
                self.onTap?(hit, point)
                return true
            }
            elements.append(element)
        }
        isAccessibilityElement = elements.isEmpty
        accessibilityElements = elements
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer) || (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let delta = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        camera.pan(byScreen: delta)
        if let clampRect { camera.clamp(to: clampRect) }
        if g.state == .ended {
            let v = g.velocity(in: self)
            if hypot(v.x, v.y) > 300 {
                var target = camera
                target.pan(byScreen: CGPoint(x: v.x * 0.12, y: v.y * 0.12))
                if let clampRect { target.clamp(to: clampRect) }
                animate(to: target, duration: 0.25)
                return
            }
        }
        onCameraChange?(camera)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard !zoomLocked else { return }
        switch g.state {
        case .began:
            pinchStartScale = camera.scale
        case .changed:
            let target = pinchStartScale * g.scale
            let factor = target / camera.scale
            camera.zoom(by: factor, around: g.location(in: self), limits: scaleLimits)
            if let clampRect { camera.clamp(to: clampRect) }
            onCameraChange?(camera)
        default:
            onCameraChange?(camera)
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        let hit = MapHitTester.hit(at: p, scene: scene, camera: camera, content: content, options: options)
        onTap?(hit, p)
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard !zoomLocked else { return }
        animateZoom(by: 2, around: g.location(in: self))
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        onLongPress?(g.location(in: self))
    }

    func animateZoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let point = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        var target = camera
        target.zoom(by: factor, around: point, limits: scaleLimits)
        if let clampRect { target.clamp(to: clampRect) }
        animate(to: target)
    }

    private struct Animation {
        let start: MapCamera
        let target: MapCamera
        let startTime: CFTimeInterval
        let duration: TimeInterval
        let link: CADisplayLink
    }

    private var animation: Animation?

    var isAnimating: Bool { animation != nil }

    /// Starts a new camera animation, stopping any running one so only one display link is ever live.
    func animate(to target: MapCamera, duration: TimeInterval = 0.3) {
        stopAnimation()
        let link = CADisplayLink(target: DisplayLinkProxy(canvas: self), selector: #selector(DisplayLinkProxy.tick))
        animation = Animation(start: camera, target: target, startTime: CACurrentMediaTime(), duration: duration, link: link)
        link.add(to: .main, forMode: .common)
    }

    func stopAnimation() {
        animation?.link.invalidate()
        animation = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopAnimation() }
    }

    fileprivate func step() {
        guard let a = animation else { return }
        let t = min(1, (CACurrentMediaTime() - a.startTime) / a.duration)
        let e = 1 - pow(1 - t, 3)
        var c = camera
        c.center = CGPoint(x: a.start.center.x + (a.target.center.x - a.start.center.x) * e, y: a.start.center.y + (a.target.center.y - a.start.center.y) * e)
        c.scale = a.start.scale * pow(a.target.scale / a.start.scale, e)
        camera = c
        if t >= 1 {
            stopAnimation()
            camera = a.target
            onCameraChange?(camera)
        }
    }
}

/// CADisplayLink retains its target; this proxy keeps the canvas weakly so the link never pins it,
/// and invalidates the link itself once the canvas is gone.
@MainActor
private final class DisplayLinkProxy: NSObject {
    private weak var canvas: MapCanvas?
    init(canvas: MapCanvas) { self.canvas = canvas }
    @objc func tick(_ link: CADisplayLink) {
        guard let canvas else { link.invalidate(); return }
        canvas.step()
    }
}

final class MarkerAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

struct MapCanvasView: UIViewRepresentable {
    @ObservedObject var model: MapViewModel
    var scaleLimits: ClosedRange<CGFloat>
    var clampRect: CGRect?

    func makeUIView(context: Context) -> MapCanvas {
        let canvas = MapCanvas(camera: model.camera, options: model.frameOptions)
        canvas.scaleLimits = scaleLimits
        canvas.clampRect = clampRect
        canvas.onCameraChange = { [weak model] camera in model?.cameraDidChange(camera) }
        canvas.onTap = { [weak model] hit, point in model?.handleTap(hit, at: point) }
        canvas.onLongPress = { [weak model] point in model?.handleLongPress(at: point) }
        model.attach(canvas)
        return canvas
    }

    func updateUIView(_ canvas: MapCanvas, context: Context) {
        canvas.scene = model.scene
        canvas.options = model.frameOptions
        canvas.content = model.frameContent
        canvas.zoomLocked = model.zoomLocked
        canvas.scaleLimits = scaleLimits
        canvas.clampRect = clampRect
        if canvas.camera != model.camera && !model.cameraFromCanvas {
            canvas.camera = model.camera
        }
        model.cameraFromCanvas = false
    }

    static func dismantleUIView(_ canvas: MapCanvas, coordinator: ()) {
        canvas.stopAnimation()
    }
}
