import Foundation
import CoreLocation

enum YosemiteGeo {
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    static let valleyCenter = CLLocationCoordinate2D(latitude: 37.7487, longitude: -119.5871)
    /// Extent of the bundled Valley geometry packs.
    static let valleyBounds = GeoBounds(west: -119.72, south: 37.69, east: -119.53, north: 37.78)
    /// Visitor core the Valley map opens on: Yosemite Lodge, the Village, The Ahwahnee, Curry Village and the Pines campgrounds.
    static let valleyCore = GeoBounds(west: -119.606, south: 37.728, east: -119.553, north: 37.754)
    /// Extent used by the park-wide schematic and the fire desk.
    static let parkBounds = GeoBounds(west: -120.05, south: 37.37, east: -119.05, north: 38.30)

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }
}

struct GeoBounds: Hashable, Codable, Sendable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2)
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= south && latitude <= north && longitude >= west && longitude <= east
    }

    func expanded(byFraction f: Double) -> GeoBounds {
        let dx = (east - west) * f, dy = (north - south) * f
        return GeoBounds(west: west - dx, south: south - dy, east: east + dx, north: north + dy)
    }
}

/// Great-circle distance in metres.
func haversineMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let r = 6_371_008.8
    let dLat = (b.latitude - a.latitude) * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * asin(min(1, sqrt(h)))
}

func compassBearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> String {
    let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let y = sin(dLon) * cos(la2)
    let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
    var deg = atan2(y, x) * 180 / .pi
    if deg < 0 { deg += 360 }
    let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return names[Int((deg + 22.5) / 45) % 8]
}

extension Measurement where UnitType == UnitLength {
    static func milesText(meters: Double) -> String {
        let miles = meters / 1609.344
        if miles < 0.1 { return "\(Int(meters * 3.28084)) ft" }
        return String(format: miles < 10 ? "%.1f mi" : "%.0f mi", miles)
    }
}
