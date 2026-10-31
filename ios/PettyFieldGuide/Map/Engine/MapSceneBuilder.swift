import Foundation
import CoreGraphics
import CoreLocation

/// The one continuous map of the park. The Valley packs keep their detail; the park-wide packs supplement them
/// with features those packs do not hold (NPS OBJECTIDs and NHD permanent ids are shared, so nothing is drawn
/// twice). Relief comes from three tiers: coarse 3DEP context, the ≈30 m 3DEP park grid and the 20 m Valley grid.
enum MapSceneBuilder {
    /// The one projection every map screen and overlay shares; centred on the Valley so its detail is exact.
    static let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)

    static func build() throws -> MapScene {
        func doc(_ name: String) throws -> GeoJSON.Document { try GeoJSON.parse(BundleContent.data(name, subdirectory: "Geo")) }

        var roads: [LineFeature] = []
        for d in try [doc("roads.geojson"), doc("park-roads.geojson")] {
            for (i, f) in d.features.enumerated() {
                let oneWay: Int = switch f.string("RDONEWAY") { case "With Digitized": 1; case "Against Digitized": -1; default: 0 }
                roads += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: f.string("RDNAME"), label: f.string("MAPLABEL"),
                                                    styleKey: roadStyle(f.string("RDCLASS") ?? "Local", surface: f.string("RDSURFACE")), oneWay: oneWay, seasonal: f.string("SEASDESC"))
            }
        }

        // park-trails.geojson holds every NPS trail feature, including the Valley pack's; those keep the Valley copy.
        let valleyTrails = try doc("trails.geojson")
        let valleyTrailIds = Set(valleyTrails.features.compactMap(\.id))
        let parkTrails = try doc("park-trails.geojson")
        let trailFeatures = valleyTrails.features + parkTrails.features.filter { !valleyTrailIds.contains($0.id ?? "") }
        // Trails whose named features add up to a long route are drawn from regional zoom; short named paths wait.
        var namedLength: [String: CGFloat] = [:]
        for f in trailFeatures {
            guard let name = f.string("TRLNAME") ?? f.string("TRLALTNAME") else { continue }
            let lines: [[CLLocationCoordinate2D]] = switch f.geometry { case .lineString(let c): [c]; case .multiLineString(let l): l; default: [] }
            namedLength[name, default: 0] += lines.reduce(0) { $0 + GeometryOps.length(projection.project($1)) }
        }
        var trails: [LineFeature] = []
        for (i, f) in trailFeatures.enumerated() {
            let name = f.string("TRLNAME") ?? f.string("TRLALTNAME")
            let style = (f.string("TRLUSE") ?? "").contains("Bicycle") || name == "Bike Path" ? "bike"
                : (name.flatMap { namedLength[$0] } ?? 0) >= majorTrailMetres ? "trail-major" : "trail"
            trails += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: name, label: f.string("MAPLABEL"), styleKey: style, seasonal: f.string("SEASDESC"))
        }

        var buildings: [AreaFeature] = []
        for d in try [doc("buildings.geojson"), doc("park-buildings.geojson")] {
            for (i, f) in d.features.enumerated() {
                buildings += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: f.string("BLDGNAME"), label: f.string("MAPLABEL"),
                                                       styleKey: f.string("BLDGSTATUS") == "Existing" ? "building" : "building-closed", numericId: f.number("OBJECTID").map { Int($0) })
            }
        }

        var parking: [AreaFeature] = []
        for d in try [doc("parking.geojson"), doc("park-parking.geojson")] {
            for (i, f) in d.features.enumerated() {
                parking += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: f.string("MAPLABEL"), label: f.string("MAPLABEL"), styleKey: "parking")
            }
        }

        var pois: [PointFeature] = []
        for d in try [doc("pois.geojson"), doc("park-pois.geojson")] {
            for (i, f) in d.features.enumerated() {
                guard case .point(let c) = f.geometry else { continue }
                pois.append(PointFeature(id: f.id ?? "poi\(i)", name: f.string("POINAME"), point: projection.project(c), coordinate: c, type: f.string("POITYPE"), attributes: f.properties))
            }
        }

        var waterLines: [LineFeature] = []
        var waterAreas: [AreaFeature] = []
        for d in try [doc("waterways.geojson"), doc("park-water.geojson")] {
            for (i, f) in d.features.enumerated() {
                let name = f.string("gnis_name") ?? f.string("name")
                switch f.geometry {
                case .lineString, .multiLineString:
                    let style = name.map { $0.hasSuffix("River") ? "river" : "stream" } ?? "stream-minor"
                    waterLines += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: name, label: name, styleKey: style)
                case .polygon, .multiPolygon:
                    waterAreas += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: name, label: name, styleKey: "water")
                case .point:
                    break
                }
            }
        }

        var boundary: [AreaFeature] = []
        for (i, f) in try doc("park-boundary.geojson").features.enumerated() {
            boundary += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: f.string("UNIT_NAME"), label: nil, styleKey: "boundary")
        }
        var scars: [AreaFeature] = []
        for (i, f) in try doc("fire-scars.geojson").features.enumerated() {
            let year = f.number("year").map { String(Int($0)) } ?? "?"
            scars += SceneBuilder.areaFeatures(from: f, index: i, projection: projection, name: "\(f.string("name") ?? "Unnamed") (\(year))", label: nil, styleKey: "fire-scar")
        }

        let trailsFetched = parkTrails.metadata["fetchedAt"].map { String($0.displayText.prefix(10)) } ?? "date not recorded"
        var sources = ["NPS public GIS buildings, parking, points of interest, roads and trails: Valley packs fetched 2026-09-21; park-wide supplements and \(parkTrails.features.count) park trail features fetched \(trailsFetched). Positional accuracy mostly not recorded",
                       "USGS National Hydrography Dataset: Valley flowlines, plus park-wide named and perennial streams, lakes and reservoirs (NHD High Resolution)",
                       "USGS GNIS official names for summits, passes, meadows, canyons, ridges and ranges",
                       "NPS park boundary (edited 2025-09-19); CAL FIRE FRAP historical fire perimeters on the fire map only"]

        var layers: [ReliefLayer] = []
        // Coarsest first: each finer tier feathers into the one beneath, the coarsest into plain land.
        let outer = try TerrainGrid.load(file: TerrainGrid.outerFile)
        layers.append(ReliefLayer(grid: outer, projection: projection, feather: outerFeather))
        let surround = try TerrainGrid.load(file: TerrainGrid.surroundFile)
        layers.append(ReliefLayer(grid: surround, projection: projection, feather: 20))
        let park = try TerrainGrid.load(file: TerrainGrid.parkFile)
        layers.append(ReliefLayer(grid: park, projection: projection, feather: 40))
        sources.append("Relief: \(park.source), fetched \(DateText.long(park.fetchedAt)); \(park.width)×\(park.height) cells at about \(Int(park.cellSizeMeters.x.rounded())) m over the park, \(Int(surround.cellSizeMeters.x.rounded())) m around it and \(Int(outer.cellSizeMeters.x.rounded())) m beyond; open ocean past 3DEP coverage is left blank")
        let detail = try TerrainGrid.load(file: TerrainGrid.basemapFile)
        layers.append(ReliefLayer(grid: detail, projection: projection, feather: 40))
        sources.append("Valley relief detail: \(detail.source), fetched \(DateText.long(detail.fetchedAt)); \(detail.width)×\(detail.height) cells at about \(Int(detail.cellSizeMeters.x.rounded())) m")
        // 50 m lines from the Valley grid where it reaches, 200 m lines from the park grid everywhere else.
        let contours = ContourBuilder.contours(from: detail.subsampled(by: 3), projection: projection, intervalMeters: 50, indexEvery: 250)
            + ContourBuilder.contours(from: park.subsampled(by: 4), projection: projection, intervalMeters: 200, indexEvery: 1000, excluding: detail.bounds, idPrefix: "park-contour")
        let labels = try placeLabels(projection: projection, terrain: park)

        let routes = try BundleContent.decode(HikeRoutesPack.self, "hike-routes.json")
        let traces = HikeRouteResolver.traces(for: routes.routes, trails: trails, projection: projection)
        sources.append("Hike routes: ordered NPS trail features resolved by tools/build_hike_routes.py (manifest generated \(routes.generated))")

        return MapScene(projection: projection, extent: projection.projectedRect(YosemiteGeo.parkBounds), roads: roads, trails: trails,
                        waterLines: waterLines, waterAreas: waterAreas, buildings: buildings, parking: parking, pois: pois, boundary: boundary,
                        fireScars: scars, contours: contours, sources: sources, relief: MapRelief(layers: layers), labels: labels, hikeRoutes: traces)
    }

    /// Park region names at overview zooms, then GNIS names as landform labels, higher summits from further out.
    /// Names the Valley's curated landmarks already label are left to them.
    private static func placeLabels(projection: LocalProjection, terrain: TerrainGrid) throws -> [SceneLabel] {
        struct Regions: Decodable {
            struct Landmark: Decodable { var name: String }
            struct Point: Decodable { var latitude: Double; var longitude: Double }
            struct Region: Decodable { var id: String; var name: String; var points: [Point] }
            var valleyLandmarks: [Landmark]
            var regions: [Region]
        }
        func normalised(_ s: String) -> String { s.lowercased().filter(\.isLetter) }
        let regions = try BundleContent.decode(Regions.self, "regions.json")
        let curated = Set(regions.valleyLandmarks.map { normalised($0.name) })
        let regionMax: CGFloat = 0.02
        var labels = [SceneLabel(id: "region-valley", text: "Yosemite Valley", point: projection.project(YosemiteGeo.valleyCenter), kind: .custom,
                                 priority: 40, minScale: 0, maxScale: regionMax)]
        for region in regions.regions where !region.points.isEmpty {
            let points = region.points.map { projection.project(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
            let centre = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            labels.append(SceneLabel(id: "region-\(region.id)", text: region.name, point: centre, kind: .custom, priority: 36, minScale: 0, maxScale: regionMax))
        }
        for f in try GeoJSON.parse(BundleContent.data("park-names.geojson", subdirectory: "Geo")).features {
            guard case .point(let c) = f.geometry, let name = f.string("name"), !curated.contains(normalised(name)) else { continue }
            let (priority, minScale): (Int, CGFloat)
            switch f.string("class") {
            case "Summit":
                let e = terrain.elevation(at: c) ?? 0
                (priority, minScale) = e >= 3700 ? (30, 0.004) : e >= 3300 ? (26, 0.008) : e >= 2900 ? (22, 0.016) : (18, 0.035)
            case "Range": (priority, minScale) = (28, 0.006)
            case "Flat", "Valley": (priority, minScale) = (16, 0.02)
            case "Gap": (priority, minScale) = (17, 0.03)
            default: (priority, minScale) = (12, 0.05)
            }
            labels.append(SceneLabel(id: f.id ?? name, text: name, point: projection.project(c), kind: .landform, priority: priority, minScale: minScale))
        }
        return labels
    }

    static let majorTrailMetres: CGFloat = 3000
    /// Few cells: the outer tier's edge lies far beyond anything but the zoom floor, which keeps clear of the fade.
    static let outerFeather = 6

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
