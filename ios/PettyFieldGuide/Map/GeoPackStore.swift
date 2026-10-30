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

    @Published private(set) var valley: SceneState = .idle
    @Published private(set) var park: SceneState = .idle
    @Published private(set) var terrain: TerrainGrid?
    @Published private(set) var campgroundScenes: [String: MapScene] = [:]
    @Published private(set) var hikeProfiles: [String: HikeProfile] = [:]
    private var valleyTask: Task<MapScene, Error>?
    private var basemapTask: Task<TerrainGrid, Error>?

    /// Every caller awaits the same build, so a second screen asking while the first is still loading
    /// gets the finished scene instead of returning early on `.loading`.
    func loadValley() async {
        switch valley {
        case .ready, .failed: return
        case .idle, .loading: break
        }
        if valleyTask == nil {
            valley = .loading
            valleyTask = Task.detached(priority: .userInitiated) { try ValleySceneBuilder.build() }
        }
        do {
            let scene = try await valleyTask!.value
            valley = .ready(scene)
        } catch {
            valley = .failed(error.localizedDescription)
        }
    }

    func loadPark() async {
        guard case .idle = park else { return }
        park = .loading
        do {
            let scene = try await Task.detached(priority: .userInitiated) { try ParkSceneBuilder.build() }.value
            park = .ready(scene)
        } catch {
            park = .failed(error.localizedDescription)
        }
    }

    func loadTerrain() async {
        guard terrain == nil else { return }
        terrain = try? await Task.detached(priority: .utility) { try TerrainGrid.load() }.value
    }

    /// Terrain profile of a hike route from the 20 m relief grid, sampled off the main actor and cached.
    func hikeProfile(for routeId: String) async -> HikeProfile? {
        if let cached = hikeProfiles[routeId] { return cached }
        await loadValley()
        guard case .ready(let scene) = valley, let trace = scene.hikeRoutes[routeId] else { return nil }
        if basemapTask == nil {
            basemapTask = Task.detached(priority: .utility) { try TerrainGrid.load(file: TerrainGrid.basemapFile) }
        }
        guard let grid = try? await basemapTask?.value else { return nil }
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
