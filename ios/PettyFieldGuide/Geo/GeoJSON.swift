import Foundation
import CoreLocation

/// Minimal GeoJSON decoding into typed geometry with string/number/bool properties.
struct GeoFeature: Sendable {
    enum Geometry: Sendable {
        case point(CLLocationCoordinate2D)
        case lineString([CLLocationCoordinate2D])
        case multiLineString([[CLLocationCoordinate2D]])
        case polygon([[CLLocationCoordinate2D]])          // outer ring first
        case multiPolygon([[[CLLocationCoordinate2D]]])
    }

    var id: String?
    var geometry: Geometry
    var properties: [String: GeoValue]

    func string(_ key: String) -> String? {
        if case .string(let s)? = properties[key] { return s }
        return nil
    }

    func number(_ key: String) -> Double? {
        if case .number(let n)? = properties[key] { return n }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let b)? = properties[key] { return b }
        return nil
    }
}

enum GeoValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case other(String)

    var displayText: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e12 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "Yes" : "No"
        case .null: "—"
        case .other(let s): s
        }
    }
}

enum GeoJSON {
    struct Document: Sendable {
        var features: [GeoFeature]
        var metadata: [String: GeoValue]
    }

    static func parse(_ data: Data) throws -> Document {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rawFeatures = root["features"] as? [[String: Any]] ?? []
        var features: [GeoFeature] = []
        features.reserveCapacity(rawFeatures.count)
        for raw in rawFeatures {
            guard let geom = raw["geometry"] as? [String: Any], let geometry = geometry(from: geom) else { continue }
            let props = (raw["properties"] as? [String: Any] ?? [:]).mapValues(value)
            let id = (raw["id"] as? String) ?? (raw["id"] as? NSNumber).map { $0.stringValue }
            features.append(GeoFeature(id: id, geometry: geometry, properties: props))
        }
        var metadata: [String: GeoValue] = [:]
        for (k, v) in root where k != "features" && k != "type" {
            metadata[k] = value(v)
        }
        return Document(features: features, metadata: metadata)
    }

    private static func value(_ any: Any) -> GeoValue {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case is NSNull: return .null
        default:
            if let data = try? JSONSerialization.data(withJSONObject: any), let s = String(data: data, encoding: .utf8) { return .other(s) }
            return .other(String(describing: any))
        }
    }

    private static func coordinate(_ any: Any) -> CLLocationCoordinate2D? {
        guard let arr = any as? [NSNumber], arr.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: arr[1].doubleValue, longitude: arr[0].doubleValue)
    }

    private static func line(_ any: Any) -> [CLLocationCoordinate2D] {
        (any as? [Any] ?? []).compactMap(coordinate)
    }

    private static func geometry(from geom: [String: Any]) -> GeoFeature.Geometry? {
        guard let type = geom["type"] as? String, let coords = geom["coordinates"] else { return nil }
        switch type {
        case "Point":
            return coordinate(coords).map { .point($0) }
        case "LineString":
            return .lineString(line(coords))
        case "MultiLineString":
            return .multiLineString((coords as? [Any] ?? []).map(line))
        case "Polygon":
            return .polygon((coords as? [Any] ?? []).map(line))
        case "MultiPolygon":
            return .multiPolygon((coords as? [Any] ?? []).map { ($0 as? [Any] ?? []).map(line) })
        default:
            return nil
        }
    }
}
