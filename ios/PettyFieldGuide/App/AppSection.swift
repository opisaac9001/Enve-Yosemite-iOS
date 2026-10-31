import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case map, directory, search, status, trails, park, navigation, events, permits, contacts, documents, fire, risks, trip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: "Map"
        case .directory: "Places"
        case .search: "Search"
        case .status: "Field status"
        case .trails: "Trails & camping"
        case .park: "Beyond the Valley"
        case .navigation: "Getting around"
        case .events: "Events"
        case .permits: "Permits & reservations"
        case .contacts: "Contacts"
        case .documents: "Documents"
        case .fire: "Fire & smoke"
        case .risks: "Seasonal risks"
        case .trip: "Trip prep"
        }
    }

    var compactTitle: String {
        switch self {
        case .status: "Status"
        case .trails: "Trails"
        case .park: "Park"
        case .navigation: "Shuttle"
        case .permits: "Permits"
        case .fire: "Fire"
        case .risks: "Risks"
        case .trip: "Trip"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .map: "map.fill"
        case .directory: "mappin.and.ellipse"
        case .search: "magnifyingglass"
        case .status: "cloud.sun.fill"
        case .trails: "figure.hiking"
        case .park: "mountain.2.fill"
        case .navigation: "bus.fill"
        case .events: "calendar"
        case .permits: "checkmark.seal.fill"
        case .contacts: "phone.fill"
        case .documents: "doc.text.fill"
        case .fire: "flame.fill"
        case .risks: "exclamationmark.triangle.fill"
        case .trip: "shippingbox.fill"
        }
    }

    var blurb: String {
        switch self {
        case .map: "Offline maps: the detailed Valley with buildings and shuttle routes, and the whole park with NPS roads, trails and trailheads."
        case .directory: "Every mapped place with hours, access, contacts and sources."
        case .search: "One search across places, sites, phones, trails, guides, events and documents."
        case .status: "Weather by forecast point, daylight, webcams and feed freshness."
        case .trails: "Twelve Valley hikes with complete mapped routes, the thirteen campgrounds and camping rules."
        case .park: "Regions, entrances, road status, chain controls and wilderness reports."
        case .navigation: "Shuttle trip planner from the published timetable."
        case .events: "Curated programs and the NPS calendar in one month view."
        case .permits: "What needs a permit, when, and how to apply."
        case .contacts: "Non-emergency numbers with menus, hours and sources."
        case .documents: "Official PDFs that work offline."
        case .fire: "Perimeters, satellite heat, smoke plumes and air monitors."
        case .risks: "Month-by-month checks with their live inputs."
        case .trip: "Offline packs, conditions snapshots, saved items and backups."
        }
    }

    /// Primary tabs shown in the floating pill bar on compact layouts.
    static let pillTabs: [AppSection] = [.map, .trails, .directory, .status]

    /// Sections grouped for the More sheet and the iPad sidebar.
    static let groups: [(title: String, sections: [AppSection])] = [
        ("Explore", [.map, .directory, .search, .trails, .park, .navigation]),
        ("Plan", [.events, .permits, .documents, .contacts, .trip]),
        ("Conditions", [.status, .fire, .risks]),
    ]
}
