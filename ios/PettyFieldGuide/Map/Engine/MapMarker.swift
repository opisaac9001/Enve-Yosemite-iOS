import CoreGraphics
import CoreLocation
import UIKit

struct MapMarker: Identifiable, Sendable {
    enum Shape: Sendable { case pin, dot, badge, stop, site, car, campsite, user }

    let id: String
    let point: CGPoint             // projected
    let title: String
    let glyph: String?             // short text drawn inside (site numbers, "H₂O", stop numbers)
    let symbol: String?            // SF Symbol name
    let colorHex: String
    let priority: Int              // higher wins collisions and cluster representation
    let shape: Shape
    let clusterable: Bool
    let minScale: CGFloat          // hidden below this zoom
    let labelMinScale: CGFloat?    // title drawn beside the marker from this zoom; nil = never
    let accessibilityTitle: String? // full name for VoiceOver when the drawn title is a compact form

    init(id: String, point: CGPoint, title: String, glyph: String? = nil, symbol: String? = nil, colorHex: String,
         priority: Int = 1, shape: Shape = .pin, clusterable: Bool = true, minScale: CGFloat = 0, labelMinScale: CGFloat? = nil,
         accessibilityTitle: String? = nil) {
        self.id = id; self.point = point; self.title = title; self.glyph = glyph; self.symbol = symbol
        self.colorHex = colorHex; self.priority = priority; self.shape = shape; self.clusterable = clusterable; self.minScale = minScale
        self.labelMinScale = labelMinScale
        self.accessibilityTitle = accessibilityTitle
    }

    var accessibleName: String { accessibilityTitle ?? title }

    static let routeStartId = "route-start"
    static let routeDestinationId = "route-destination"

    /// Wide-zoom clustering family; nil never merges.
    var clusterFamily: String? {
        guard clusterable else { return nil }
        return shape == .stop ? "stop" : "place"
    }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: CGFloat
        if s.count == 6 {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255
        } else {
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
