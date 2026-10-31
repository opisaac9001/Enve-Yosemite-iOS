import Foundation
import Combine

/// Builds and caches projected scenes off the main actor; each scene is built once per launch.
@MainActor
final class GeoPackStore: ObservableObject {
    static let shared = GeoPackStore()

    enum SceneState {
        case idle
        case loading
        case ready(MapScene)
        case failed(String)
    }

    /// The continuous park map every screen draws: the Map tab, the region and fire maps and the hike maps.
    @Published private(set) var map: SceneState = .idle
    @Published private(set) var terrain: TerrainGrid?
    @Published private(set) var campgroundScenes: [String: MapScene] = [:]
    @Published private(set) var hikeProfiles: [String: HikeProfile] = [:]
    private var mapTask: Task<MapScene, Error>?
    private var basemapTask: Task<TerrainGrid, Error>?
    private var parkGridTask: Task<TerrainGrid, Error>?

    /// Every caller awaits the same build, so a second screen asking while the first is still loading
    /// gets the finished scene instead of returning early on `.loading`.
    func loadMap() async {
        switch map {
        case .ready, .failed: return
        case .idle, .loading: break
        }
        if mapTask == nil {
            map = .loading
            mapTask = Task.detached(priority: .userInitiated) { try MapSceneBuilder.build() }
        }
        do {
            let scene = try await mapTask!.value
            map = .ready(scene)
        } catch {
            map = .failed(error.localizedDescription)
        }
    }

    func loadTerrain() async {
        guard terrain == nil else { return }
        terrain = try? await Task.detached(priority: .utility) { try TerrainGrid.load() }.value
    }

    /// The loaded map scene, which holds every resolved hike route.
    func scene() async -> MapScene? {
        await loadMap()
        if case .ready(let scene) = map { return scene }
        return nil
    }

    /// Terrain profile of a hike route, sampled off the main actor and cached: routes traced on the Valley pack
    /// use the 20 m Valley grid, park-pack routes the ≈30 m 3DEP park grid. Nil when the route leaves the grid.
    func hikeProfile(for routeId: String, pack: HikeRouteGeometry = .valley) async -> HikeProfile? {
        if let cached = hikeProfiles[routeId] { return cached }
        guard let scene = await scene(), let trace = scene.hikeRoutes[routeId] else { return nil }
        let task: Task<TerrainGrid, Error>
        switch pack {
        case .valley:
            if basemapTask == nil { basemapTask = Task.detached(priority: .utility) { try TerrainGrid.load(file: TerrainGrid.basemapFile) } }
            task = basemapTask!
        case .park:
            if parkGridTask == nil { parkGridTask = Task.detached(priority: .utility) { try TerrainGrid.load(file: TerrainGrid.parkFile) } }
            task = parkGridTask!
        }
        guard let grid = try? await task.value else { return nil }
        let projection = scene.projection
        let profile = await Task.detached(priority: .utility) { HikeRouteResolver.profile(for: trace, grid: grid, projection: projection) }.value
        if let profile { hikeProfiles[routeId] = profile }
        return profile
    }

    func campgroundScene(_ campgroundId: String) async -> MapScene? {
        if let cached = campgroundScenes[campgroundId] { return cached }
        let scene = try? await Task.detached(priority: .userInitiated) { try CampgroundSceneBuilder.build(campgroundId: campgroundId) }.value
        if let scene { campgroundScenes[campgroundId] = scene }
        return scene
    }
}
