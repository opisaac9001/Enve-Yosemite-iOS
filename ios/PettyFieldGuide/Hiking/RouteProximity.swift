import Foundation
import CoreGraphics

/// Where a live fix sits relative to a selected route's mapped line, in projected metres. Passive
/// orientation only: nothing here alerts, and the figures are withheld whenever the fix can't support them.
enum RouteProximity: Equatable {
    enum Withheld: Equatable { case stale, weak, approximate }

    case withheld(Withheld)
    /// Near the line: the offset from it and the nearest point's distance along the one-pass trace.
    case onRoute(offsetMetres: Double, alongMetres: Double, remainingMetres: Double)
    /// Near a stretch the route covers more than once, so the position along it can't be told.
    case ambiguous(offsetMetres: Double)
    case away(offsetMetres: Double)

    /// Accuracy estimates worse than this withhold every route figure.
    static let maxAccuracyMetres = 50.0
    /// Past this, or past the accuracy radius when that is larger, only the distance from the line is given.
    static let nearMetres = 75.0

    static func evaluate(fix: CGPoint, accuracy: Double, stale: Bool, reducedAccuracy: Bool, line: [CGPoint]) -> RouteProximity {
        if stale { return .withheld(.stale) }
        if reducedAccuracy { return .withheld(.approximate) }
        guard accuracy >= 0, accuracy <= maxAccuracyMetres, line.count > 1 else { return .withheld(.weak) }

        var candidates: [(offset: Double, along: Double)] = []
        candidates.reserveCapacity(line.count - 1)
        var travelled = 0.0
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let length = hypot(dx, dy)
            let t = length > 0 ? max(0, min(1, (Double(fix.x - a.x) * dx + Double(fix.y - a.y) * dy) / (length * length))) : 0
            candidates.append((hypot(Double(a.x) + t * dx - Double(fix.x), Double(a.y) + t * dy - Double(fix.y)), travelled + t * length))
            travelled += length
        }
        let nearest = candidates.min { $0.offset < $1.offset }!
        guard nearest.offset <= max(nearMetres, accuracy) else { return .away(offsetMetres: nearest.offset) }
        // Every stretch inside the accuracy band could be where the fix really is; if those stretches are far
        // apart along the route (switchbacks, a shared out-and-back stem, a loop's start and finish) the
        // nearest one is a guess.
        let band = nearest.offset + max(accuracy, 10)
        let alongs = candidates.filter { $0.offset <= band }.map(\.along)
        if alongs.max()! - alongs.min()! > 2 * band + 50 { return .ambiguous(offsetMetres: nearest.offset) }
        return .onRoute(offsetMetres: nearest.offset, alongMetres: nearest.along, remainingMetres: travelled - nearest.along)
    }

    func text(kind: HikeRouteKind) -> String {
        switch self {
        case .withheld(.stale): "Route distances are hidden while the fix is out of date."
        case .withheld(.weak): "Route distances appear once iOS reports ±\(Int(Self.maxAccuracyMetres)) m or better."
        case .withheld(.approximate): "Route distances need Precise Location."
        case .away(let offset): "About \(Self.distance(offset)) from this route's mapped line."
        case .ambiguous(let offset):
            "\(Self.offsetPhrase(offset)) The route passes here more than once, so progress along it can't be told from position."
        case .onRoute(let offset, let along, let remaining):
            "\(Self.offsetPhrase(offset)) Nearest mapped point: \(HikeFormat.inspectionMiles(along)) from the start, \(HikeFormat.inspectionMiles(remaining)) \(Self.remainder(kind))."
        }
    }

    private static func remainder(_ kind: HikeRouteKind) -> String {
        switch kind {
        case .outAndBack: "before the turnaround"
        case .loop: "to the end of the loop in its mapped direction"
        case .oneWay: "to the finish"
        }
    }

    private static func offsetPhrase(_ metres: Double) -> String {
        metres < 10 ? "Within 10 m of the mapped line." : "About \(distance(metres)) from the mapped line."
    }

    private static func distance(_ metres: Double) -> String {
        metres < 1000 ? "\(Int((metres / 5).rounded() * 5)) m" : HikeFormat.inspectionMiles(metres)
    }
}
