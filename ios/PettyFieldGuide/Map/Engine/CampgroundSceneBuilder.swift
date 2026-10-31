import Foundation
import CoreGraphics
import CoreLocation

/// Campground site-map scene: campground roads and restroom points from NPS GIS, framed per campground.
enum CampgroundSceneBuilder {
    struct Frame: Decodable { var south: Double; var north: Double; var west: Double; var east: Double }

    static func frames() throws -> [String: Frame] {
        struct Doc: Decodable { var frames: [String: Frame] }
        return try JSONDecoder().decode(Doc.self, from: BundleContent.data("campground-context.geojson", subdirectory: "Geo")).frames
    }

    static func build(campgroundId: String) throws -> MapScene {
        let doc = try GeoJSON.parse(BundleContent.data("campground-context.geojson", subdirectory: "Geo"))
        let frames = try frames()
        guard let frame = frames[campgroundId] else { throw CocoaError(.fileNoSuchFile) }
        let bounds = GeoBounds(west: frame.west, south: frame.south, east: frame.east, north: frame.north)
        let projection = LocalProjection(origin: bounds.center)
        var roads: [LineFeature] = []
        var pois: [PointFeature] = []
        for (i, f) in doc.features.enumerated() where f.string("campground") == campgroundId {
            switch f.string("kind") {
            case "road":
                let oneWay: Int = switch f.string("oneWay") { case "With Digitized": 1; case "Against Digitized": -1; default: 0 }
                roads += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: f.string("name"), label: f.string("name"),
                                                    styleKey: f.string("roadClass") == "Secondary" ? "road-local" : "road-service", oneWay: oneWay, seasonal: f.string("seasonal"))
            case "restroom":
                if case .point(let c) = f.geometry {
                    pois.append(PointFeature(id: f.id ?? "cr\(i)", name: f.string("name") ?? "Restroom", point: projection.project(c), coordinate: c, type: "Restroom", attributes: f.properties))
                }
            default:
                break
            }
        }
        return MapScene(projection: projection, extent: projection.projectedRect(bounds), roads: roads, trails: [], waterLines: [], waterAreas: [],
                        buildings: [], parking: [], pois: pois, boundary: [], fireScars: [], contours: [],
                        sources: ["NPS public GIS campground roads and restroom points (fetched 2026-10-22)", "Recreation.gov RIDB campsite inventory (fetched 2026-10-22)"])
    }
}
