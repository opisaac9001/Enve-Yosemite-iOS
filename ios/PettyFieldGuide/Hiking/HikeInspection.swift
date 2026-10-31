import Foundation
import CoreGraphics

enum HikeLeg: Equatable, Sendable {
    case outward, back

    var title: String { self == .outward ? "outward" : "return" }
}

/// A sourced milestone on the travelled line; out-and-backs get mirrored return entries with their own ids.
struct HikeLandmark: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let role: String        // start | waypoint | destination | finish
    let metres: Double
    let point: CGPoint      // on the travelled line, not the milestone's own (possibly offset) coordinate
    let leg: HikeLeg?
    let approximate: Bool

    var displayName: String { leg == .back ? "\(name) (return)" : name }
    var compactName: String {
        let cut = name.firstIndex { $0 == "(" || $0 == "," } ?? name.endIndex
        return name[..<cut].trimmingCharacters(in: .whitespaces)
    }

    static func landmarks(for route: HikeRoute, trace: MapRouteTrace) -> [HikeLandmark] {
        let chainage = trace.chainage
        let turnaround = trace.turnaroundMetres
        let total = chainage.totalMetres
        let rows = route.milestoneRows
        func outward(_ m: HikeMilestone) -> Double {
            switch m.role {
            case "start": 0
            case "destination": turnaround
            default: min(max(m.chainageMiles * 1609.344, 0), turnaround)
            }
        }
        var out = rows.map { row -> HikeLandmark in
            let metres = outward(row.milestone)
            return HikeLandmark(id: row.id, name: row.milestone.name, role: row.milestone.role, metres: metres, point: chainage.point(at: metres),
                                leg: route.kind == .outAndBack ? .outward : nil, approximate: row.milestone.isApproximate)
        }
        if route.kind == .outAndBack {
            for row in rows.dropFirst().dropLast().reversed() {
                let metres = total - outward(row.milestone)
                out.append(HikeLandmark(id: "return-\(row.id)", name: row.milestone.name, role: "waypoint", metres: metres, point: chainage.point(at: metres),
                                        leg: .back, approximate: row.milestone.isApproximate))
            }
            out.append(HikeLandmark(id: "return-\(rows[0].id)", name: route.start.name, role: "finish", metres: total, point: chainage.point(at: total),
                                    leg: .back, approximate: false))
        }
        return out
    }
}

struct HikeInspection: Equatable {
    let metres: Double
    let elevationMetres: Double
    let gradePercent: Double?   // positive when climbing in travel direction; nil when too little line is available
    let point: CGPoint
    let leg: HikeLeg?
    let at: HikeLandmark?
    let previous: HikeLandmark?
    let next: HikeLandmark?

    var distanceText: String { HikeFormat.inspectionMiles(metres) }

    var gradeText: String? {
        guard let gradePercent else { return nil }
        if abs(gradePercent) < 2 { return "about level" }
        return String(format: "≈%.0f%% %@", abs(gradePercent), gradePercent > 0 ? "climb" : "descent")
    }

    var headline: String {
        var parts = [distanceText, "≈\(HikeFormat.feet(metres: elevationMetres))"]
        if let gradeText { parts.append(gradeText) }
        if let leg { parts.append(at?.role == "destination" ? "turnaround" : leg.title) }
        return parts.joined(separator: " · ")
    }

    var landmarkText: String {
        if let at { return "At \(at.displayName)" }
        var parts: [String] = []
        if let previous { parts.append("\(Self.span(metres - previous.metres)) past \(previous.displayName)") }
        if let next { parts.append("\(Self.span(next.metres - metres)) to \(next.displayName)") }
        return parts.joined(separator: " · ")
    }

    var accessibilitySummary: String {
        var parts = [String(format: "%.1f miles along the route", metres / 1609.344) + (leg.map { ", \($0.title) pass" } ?? "")]
        parts.append("about \(Int((elevationMetres * 3.28084).rounded()).formatted(.number.grouping(.automatic))) feet")
        if let gradePercent {
            parts.append(abs(gradePercent) < 2 ? "about level" : String(format: "approximate grade %.0f percent %@", abs(gradePercent), gradePercent > 0 ? "climb" : "descent"))
        }
        if let at { parts.append("at \(at.displayName)") } else {
            if let previous { parts.append("\(Self.span(metres - previous.metres, spoken: true)) past \(previous.displayName)") }
            if let next { parts.append("\(Self.span(next.metres - metres, spoken: true)) to \(next.displayName)") }
        }
        return parts.joined(separator: ". ") + "."
    }

    private static func span(_ metres: Double, spoken: Bool = false) -> String {
        if metres < 160 {
            let feet = Int((metres * 3.28084 / 50).rounded() * 50)
            return spoken ? "\(feet) feet" : "\(feet) ft"
        }
        return String(format: spoken ? "%.1f miles" : "%.1f mi", metres / 1609.344)
    }
}

struct HikeInspector: Equatable {
    let routeId: String
    let kind: HikeRouteKind
    let chainage: HikeChainage
    let turnaroundMetres: Double
    let profile: HikeProfile
    let landmarks: [HikeLandmark]

    /// 200 m of 20 m terrain samples is the coarsest credible slope window.
    static let gradeHalfWindowMetres = 100.0
    static let landmarkSnapMetres = 20.0

    init(route: HikeRoute, trace: MapRouteTrace, profile: HikeProfile) {
        routeId = route.id
        kind = route.kind
        chainage = trace.chainage
        turnaroundMetres = trace.turnaroundMetres
        self.profile = profile
        landmarks = HikeLandmark.landmarks(for: route, trace: trace)
    }

    var totalMetres: Double { chainage.totalMetres }
    var stepMetres: Double { max(20, totalMetres / 40) }

    static func == (lhs: HikeInspector, rhs: HikeInspector) -> Bool { lhs.routeId == rhs.routeId && lhs.profile == rhs.profile }

    func leg(at metres: Double) -> HikeLeg? {
        guard kind == .outAndBack else { return nil }
        return metres <= turnaroundMetres ? .outward : .back
    }

    func elevation(at metres: Double) -> Double {
        let samples = profile.samples
        let target = min(max(metres, 0), profile.totalMetres)
        var low = 1, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].distanceMetres < target { low = mid + 1 } else { high = mid }
        }
        let a = samples[low - 1], b = samples[low]
        let span = b.distanceMetres - a.distanceMetres
        let t = span > 0 ? (target - a.distanceMetres) / span : 0
        return a.elevationMetres + (b.elevationMetres - a.elevationMetres) * t
    }

    /// Window stays inside the current pass so a summit turnaround is not averaged with its own descent.
    func grade(at metres: Double) -> Double? {
        let (passStart, passEnd): (Double, Double) = switch leg(at: metres) {
        case .outward: (0, turnaroundMetres)
        case .back: (turnaroundMetres, totalMetres)
        case nil: (0, totalMetres)
        }
        let low = max(passStart, metres - Self.gradeHalfWindowMetres)
        let high = min(passEnd, metres + Self.gradeHalfWindowMetres)
        guard high - low >= Self.gradeHalfWindowMetres else { return nil }
        return (elevation(at: high) - elevation(at: low)) / (high - low) * 100
    }

    func inspection(at raw: Double) -> HikeInspection {
        let metres = min(max(raw, 0), totalMetres)
        let at = landmarks.first { abs($0.metres - metres) <= Self.landmarkSnapMetres }
        let previous: HikeLandmark?, next: HikeLandmark?
        if let at, let index = landmarks.firstIndex(where: { $0.id == at.id }) {
            previous = index > 0 ? landmarks[index - 1] : nil
            next = index + 1 < landmarks.count ? landmarks[index + 1] : nil
        } else {
            previous = landmarks.last { $0.metres <= metres }
            next = landmarks.first { $0.metres > metres }
        }
        return HikeInspection(metres: metres, elevationMetres: elevation(at: metres), gradePercent: grade(at: metres), point: chainage.point(at: metres),
                              leg: leg(at: metres), at: at, previous: previous, next: next)
    }

    func landmark(_ id: String) -> HikeLandmark? { landmarks.first { $0.id == id } }

    func nextLandmark(after metres: Double?) -> HikeLandmark? {
        guard let metres else { return landmarks.first }
        return landmarks.first { $0.metres > metres + Self.landmarkSnapMetres }
    }

    func previousLandmark(before metres: Double?) -> HikeLandmark? {
        guard let metres else { return nil }
        return landmarks.last { $0.metres < metres - Self.landmarkSnapMetres }
    }

    func step(from metres: Double?, forward: Bool) -> Double {
        let current = metres ?? 0
        return forward ? min(totalMetres, current + stepMetres) : max(0, current - stepMetres)
    }
}

enum HikeInspectorLoad: Equatable {
    case loading
    case ready(HikeInspector)
    case unavailable
}

extension GeoPackStore {
    func hikeInspector(for route: HikeRoute) async -> HikeInspector? {
        guard let profile = await hikeProfile(for: route.id, pack: route.pack), let trace = await scene()?.hikeRoutes[route.id] else { return nil }
        return HikeInspector(route: route, trace: trace, profile: profile)
    }
}
