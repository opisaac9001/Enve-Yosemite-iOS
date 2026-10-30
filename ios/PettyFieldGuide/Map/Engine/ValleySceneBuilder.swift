import Foundation
import CoreGraphics
import CoreLocation

/// Builds the detailed Valley scene from the bundled NPS, NHD and terrain packs.
enum ValleySceneBuilder {
    static func build() throws -> MapScene {
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        let roadsDoc = try GeoJSON.parse(BundleContent.data("roads.geojson", subdirectory: "Geo"))
        let trailsDoc = try GeoJSON.parse(BundleContent.data("trails.geojson", subdirectory: "Geo"))
        let buildingsDoc = try GeoJSON.parse(BundleContent.data("buildings.geojson", subdirectory: "Geo"))
        let parkingDoc = try GeoJSON.parse(BundleContent.data("parking.geojson", subdirectory: "Geo"))
        let poisDoc = try GeoJSON.parse(BundleContent.data("pois.geojson", subdirectory: "Geo"))
        let waterDoc = try GeoJSON.parse(BundleContent.data("waterways.geojson", subdirectory: "Geo"))

        var roads: [LineFeature] = []
        for (i, f) in roadsDoc.features.enumerated() {
            let cls = f.string("RDCLASS") ?? "Local"
            let oneWay: Int = switch f.string("RDONEWAY") { case "With Digitized": 1; case "Against Digitized": -1; default: 0 }
            roads += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: f.string("RDNAME"), label: f.string("MAPLABEL"),
                                                styleKey: roadStyle(cls, surface: f.string("RDSURFACE")), oneWay: oneWay, seasonal: f.string("SEASDESC"))
        }

        var trails: [LineFeature] = []
        for (i, f) in trailsDoc.features.enumerated() {
            let use = f.string("TRLUSE") ?? ""
            let name = f.string("TRLNAME") ?? f.string("TRLALTNAME")
            let style = use.contains("Bicycle") || name == "Bike Path" ? "bike" : "trail"
            trails += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: name, label: f.string("MAPLABEL"), styleKey: style)
        }

        var buildings: [AreaFeature] = []
        for (i, f) in buildingsDoc.features.enumerated() {
            let name = f.string("BLDGNAME")
            let numericId = f.number("OBJECTID").map { Int($0) }
            buildings += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: name, label: f.string("MAPLABEL"),
                                                   styleKey: f.string("BLDGSTATUS") == "Existing" ? "building" : "building-closed", numericId: numericId)
        }

        var parking: [AreaFeature] = []
        for (i, f) in parkingDoc.features.enumerated() {
            parking += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: f.string("MAPLABEL"), label: f.string("MAPLABEL"), styleKey: "parking")
        }

        var pois: [PointFeature] = []
        for (i, f) in poisDoc.features.enumerated() {
            guard case .point(let c) = f.geometry else { continue }
            pois.append(PointFeature(id: f.id ?? "poi\(i)", name: f.string("POINAME"), point: projection.project(c), coordinate: c, type: f.string("POITYPE"), attributes: f.properties))
        }

        var waterLines: [LineFeature] = []
        var waterAreas: [AreaFeature] = []
        for (i, f) in waterDoc.features.enumerated() {
            let name = f.string("gnis_name") ?? f.string("name")
            switch f.geometry {
            case .lineString, .multiLineString:
                waterLines += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: name, label: name, styleKey: name == "Merced River" ? "river" : "stream")
            case .polygon, .multiPolygon:
                waterAreas += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: name, label: name, styleKey: "water")
            case .point:
                break
            }
        }

        var sources = ["NPS public GIS (buildings, parking, points of interest, roads, trails) fetched 2026-09-21",
                       "USGS National Hydrography Dataset flowlines (Merced River and tributaries)"]
        var tiers: [ReliefTier] = []
        var contours: [LineFeature] = []
        // Coarse background first; the detail tier feathers into it, the background feathers into plain land.
        for (file, feather, role) in [(TerrainGrid.regionFile, 60, "background"), (TerrainGrid.basemapFile, 40, "detail")] {
            guard let grid = try? TerrainGrid.load(file: file), let tier = ReliefRenderer.tier(grid: grid, projection: projection, feather: feather) else { continue }
            tiers.append(tier)
            sources.append("Relief \(role): \(grid.source), fetched \(DateText.long(grid.fetchedAt)); \(grid.width)×\(grid.height) cells at about \(Int(grid.cellSizeMeters.x.rounded())) m")
            if role == "detail" {
                contours = ContourBuilder.contours(from: grid.subsampled(by: 3), projection: projection, intervalMeters: 50)
            }
        }

        let routes = try BundleContent.decode(HikeRoutesPack.self, "hike-routes.json")
        let traces = HikeRouteResolver.traces(for: routes.routes, trails: trails, projection: projection)
        sources.append("Hike routes: ordered NPS trail features resolved by tools/build_hike_routes.py (manifest generated \(routes.generated))")

        let extent = projection.projectedRect(YosemiteGeo.valleyBounds)
        return MapScene(projection: projection, extent: extent, roads: roads, trails: trails, waterLines: waterLines, waterAreas: waterAreas,
                        buildings: buildings, parking: parking, pois: pois, boundary: [], fireScars: [], contours: contours, sources: sources,
                        relief: tiers.isEmpty ? nil : MapRelief(tiers: tiers), hikeRoutes: traces)
    }

    private static func roadStyle(_ cls: String, surface: String?) -> String {
        switch cls {
        case "Secondary": return "road-secondary"
        case "Local": return "road-local"
        case "Service": return "road-service"
        case "Parking Lot Road": return "road-parking"
        case "Private": return "road-private"
        default: return surface == "Asphalt" ? "road-local" : "road-service"
        }
    }
}

extension LocalProjection {
    func projectedRect(_ b: GeoBounds) -> CGRect {
        let sw = project(CLLocationCoordinate2D(latitude: b.south, longitude: b.west))
        let ne = project(CLLocationCoordinate2D(latitude: b.north, longitude: b.east))
        return CGRect(x: sw.x, y: sw.y, width: ne.x - sw.x, height: ne.y - sw.y)
    }
}
