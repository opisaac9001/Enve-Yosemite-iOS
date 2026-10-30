import CoreGraphics
import CoreLocation
import UIKit

/// Projected-metre camera. `scale` is screen points per metre; north is always up.
struct MapCamera: Equatable, Sendable {
    var center: CGPoint
    var scale: CGFloat
    var viewSize: CGSize = .zero

    func screenPoint(for projected: CGPoint) -> CGPoint {
        CGPoint(x: (projected.x - center.x) * scale + viewSize.width / 2,
                y: viewSize.height / 2 - (projected.y - center.y) * scale)
    }

    func projectedPoint(for screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - viewSize.width / 2) / scale + center.x,
                y: center.y - (screen.y - viewSize.height / 2) / scale)
    }

    /// Visible projected rectangle (metres), with optional margin in screen points.
    func visibleRect(margin: CGFloat = 0) -> CGRect {
        let w = (viewSize.width + 2 * margin) / scale
        let h = (viewSize.height + 2 * margin) / scale
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    /// Affine transform mapping projected metres to screen points, for drawing whole paths.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: viewSize.width / 2, y: viewSize.height / 2)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -center.x, y: -center.y)
    }

    mutating func zoom(by factor: CGFloat, around screenAnchor: CGPoint, limits: ClosedRange<CGFloat>) {
        let before = projectedPoint(for: screenAnchor)
        scale = min(max(scale * factor, limits.lowerBound), limits.upperBound)
        let after = projectedPoint(for: screenAnchor)
        center.x += before.x - after.x
        center.y += before.y - after.y
    }

    mutating func pan(byScreen delta: CGPoint) {
        center.x -= delta.x / scale
        center.y += delta.y / scale
    }

    static func fitting(_ rect: CGRect, in viewSize: CGSize, padding: CGFloat = 24) -> MapCamera {
        fitting(rect, in: viewSize, insets: .zero, padding: padding)
    }

    /// Fits `rect` into the part of the view not covered by chrome, so the framed area is centred
    /// in the visible gap rather than behind the search bar or the floating app bar.
    static func fitting(_ rect: CGRect, in viewSize: CGSize, insets: UIEdgeInsets, padding: CGFloat = 24, maxScale: CGFloat = .infinity) -> MapCamera {
        guard rect.width > 0, rect.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return MapCamera(center: CGPoint(x: rect.midX, y: rect.midY), scale: 0.05, viewSize: viewSize)
        }
        let usableWidth = max(40, viewSize.width - insets.left - insets.right - 2 * padding)
        let usableHeight = max(40, viewSize.height - insets.top - insets.bottom - 2 * padding)
        let scale = min(maxScale, max(0.0001, min(usableWidth / rect.width, usableHeight / rect.height)))
        let usableCentre = CGPoint(x: (insets.left + viewSize.width - insets.right) / 2, y: (insets.top + viewSize.height - insets.bottom) / 2)
        let center = CGPoint(x: rect.midX - (usableCentre.x - viewSize.width / 2) / scale,
                             y: rect.midY + (usableCentre.y - viewSize.height / 2) / scale)
        return MapCamera(center: center, scale: scale, viewSize: viewSize)
    }

    mutating func clamp(to rect: CGRect) {
        let visible = visibleRect()
        if visible.width >= rect.width { center.x = rect.midX } else {
            center.x = min(max(center.x, rect.minX + visible.width / 2), rect.maxX - visible.width / 2)
        }
        if visible.height >= rect.height { center.y = rect.midY } else {
            center.y = min(max(center.y, rect.minY + visible.height / 2), rect.maxY - visible.height / 2)
        }
    }
}
