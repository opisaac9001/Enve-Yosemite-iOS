import Foundation
import CoreGraphics
import CoreLocation

/// Park-wide schematic scene: boundary, park roads, park points of interest and historical fire perimeters.
enum ParkSceneBuilder {
    static func build() throws -> MapScene {
        let projection = LocalProjection(origin: YosemiteGeo.parkBounds.center)
        let roadsDoc = try GeoJSON.parse(BundleContent.data("park-roads.geojson", subdirectory: "Geo"))
        let poisDoc = try GeoJSON.parse(BundleContent.data("park-pois.geojson", subdirectory: "Geo"))
        let boundaryDoc = try GeoJSON.parse(BundleContent.data("park-boundary.geojson", subdirectory: "Geo"))
        let scarsDoc = try GeoJSON.parse(BundleContent.data("fire-scars.geojson", subdirectory: "Geo"))

        var roads: [LineFeature] = []
        for (i, f) in roadsDoc.features.enumerated() {
            let cls = f.string("RDCLASS") == "Secondary" ? "road-secondary" : "road-local"
            roads += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: f.string("RDNAME"), label: f.string("RDNAME"), styleKey: cls, seasonal: f.string("SEASDESC"))
        }
        var pois: [PointFeature] = []
        for (i, f) in poisDoc.features.enumerated() {
            guard case .point(let c) = f.geometry else { continue }
            pois.append(PointFeature(id: f.id ?? "ppoi\(i)", name: f.string("POINAME"), point: projection.project(c), coordinate: c, type: f.string("POITYPE"), attributes: f.properties))
        }
        var boundary: [AreaFeature] = []
        for (i, f) in boundaryDoc.features.enumerated() {
            boundary += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: f.string("UNIT_NAME"), label: nil, styleKey: "boundary")
        }
        var scars: [AreaFeature] = []
        for (i, f) in scarsDoc.features.enumerated() {
            let year = f.number("year").map { String(Int($0)) } ?? "?"
            let name = f.string("name") ?? "Unnamed"
            scars += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: "\(name) (\(year))", label: nil, styleKey: "fire-scar")
        }
        let extent = projection.projectedRect(YosemiteGeo.parkBounds)
        return MapScene(projection: projection, extent: extent, roads: roads, trails: [], waterLines: [], waterAreas: [], buildings: [], parking: [],
                        pois: pois, boundary: boundary, fireScars: scars, contours: [],
                        sources: ["NPS public GIS park roads and points of interest (fetched 2026-09-21)",
                                  "NPS boundary dataset (edited 2025-09-19)",
                                  "CAL FIRE FRAP historical fire perimeters"])
    }
}

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
