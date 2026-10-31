import CoreLocation

/// What the Map tab's continuous map can show: anything inside the park bounds its terrain and packs cover.
enum MapCoverage {
    static func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        YosemiteGeo.parkBounds.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Whether `focus` names something the map can place; false for unknown ids and points beyond the bundled terrain.
    static func canShow(_ focus: MapFocus, content: Content) -> Bool {
        switch focus {
        case .hikeRoute(let id):
            return content.hikeRoute(id) != nil
        case .trail(let id):
            return content.defaultHikeRoute(for: id) != nil || content.trail(id).map { !$0.isValley } == true
        case .place(let id):
            return content.defaultHikeRoute(for: id) != nil || content.place(id).map { contains($0.coordinate) } == true
        case .site(_, let ridbId):
            return content.campsites.first { $0.ridbId == ridbId }.map { contains($0.coordinate) } == true
        case .coordinate(let latitude, let longitude, _):
            return contains(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        case .region(let id):
            return content.region(id) != nil
        case .park:
            return true
        }
    }
}
