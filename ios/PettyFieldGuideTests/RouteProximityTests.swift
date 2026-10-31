import XCTest
import CoreGraphics
@testable import PettyFieldGuide

/// Live position against a selected route: figures only from fresh, precise, accurate fixes, and no
/// guess at progress where the route passes the same ground twice.
final class RouteProximityTests: XCTestCase {
    private let straight = [CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 0), CGPoint(x: 1000, y: 0)]

    private func evaluate(_ fix: CGPoint, accuracy: Double = 10, stale: Bool = false, reduced: Bool = false, line: [CGPoint]? = nil) -> RouteProximity {
        RouteProximity.evaluate(fix: fix, accuracy: accuracy, stale: stale, reducedAccuracy: reduced, line: line ?? straight)
    }

    func testUnusableFixesWithholdEveryFigure() {
        XCTAssertEqual(evaluate(CGPoint(x: 400, y: 5), stale: true), .withheld(.stale))
        XCTAssertEqual(evaluate(CGPoint(x: 400, y: 5), reduced: true), .withheld(.approximate))
        XCTAssertEqual(evaluate(CGPoint(x: 400, y: 5), accuracy: 51), .withheld(.weak))
        XCTAssertEqual(evaluate(CGPoint(x: 400, y: 5), accuracy: -1), .withheld(.weak), "iOS reports a negative accuracy for an invalid fix")
        XCTAssertEqual(evaluate(CGPoint(x: 400, y: 5), accuracy: 50), .onRoute(offsetMetres: 5, alongMetres: 400, remainingMetres: 600))
    }

    func testNearestPointGivesOffsetAndBothDistances() {
        guard case .onRoute(let offset, let along, let remaining) = evaluate(CGPoint(x: 730, y: -20)) else { return XCTFail() }
        XCTAssertEqual(offset, 20, accuracy: 1e-6)
        XCTAssertEqual(along, 730, accuracy: 1e-6)
        XCTAssertEqual(remaining, 270, accuracy: 1e-6)
    }

    func testFarFixesReportOnlyTheDistanceFromTheLine() {
        XCTAssertEqual(evaluate(CGPoint(x: 400, y: 76)), .away(offsetMetres: 76))
        XCTAssertEqual(evaluate(CGPoint(x: 1300, y: 400)), .away(offsetMetres: 500))
        // A wide but acceptable accuracy circle widens "near" to its own radius.
        guard case .onRoute = evaluate(CGPoint(x: 400, y: 70), accuracy: 45) else { return XCTFail() }
        XCTAssertEqual(evaluate(CGPoint(x: 400, y: 90), accuracy: 45), .away(offsetMetres: 90))
    }

    func testParallelStretchesWithinTheAccuracyBandAreAmbiguous() {
        let switchback = [CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 0), CGPoint(x: 500, y: 30), CGPoint(x: 0, y: 30)]
        XCTAssertEqual(evaluate(CGPoint(x: 250, y: 12), accuracy: 10, line: switchback), .ambiguous(offsetMetres: 12))
        // Far enough apart for the accuracy, the nearer leg is reported.
        guard case .onRoute(_, let along, _) = evaluate(CGPoint(x: 250, y: 2), accuracy: 5, line: [CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 0), CGPoint(x: 500, y: 60), CGPoint(x: 0, y: 60)]) else {
            return XCTFail()
        }
        XCTAssertEqual(along, 250, accuracy: 1e-6)
    }

    func testLoopStartAndFinishCannotBeToldApart() {
        let loop = [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0), CGPoint(x: 400, y: 400), CGPoint(x: 0, y: 400), CGPoint(x: 0, y: 0)]
        XCTAssertEqual(evaluate(CGPoint(x: 3, y: 3), line: loop), .ambiguous(offsetMetres: 3))
        guard case .onRoute(_, let along, let remaining) = evaluate(CGPoint(x: 400, y: 200), line: loop) else { return XCTFail() }
        XCTAssertEqual(along, 600, accuracy: 1e-6)
        XCTAssertEqual(remaining, 1000, accuracy: 1e-6)
    }

    func testWordingNamesTheRouteKindsEndAndNeverClaimsToBeOnTheTrail() {
        let near = RouteProximity.onRoute(offsetMetres: 4, alongMetres: 1609.344, remainingMetres: 3218.688)
        XCTAssertEqual(near.text(kind: .outAndBack), "Within 10 m of the mapped line. Nearest mapped point: 1.0 mi from the start, 2.0 mi before the turnaround.")
        XCTAssertTrue(near.text(kind: .loop).contains("in its mapped direction"))
        XCTAssertTrue(near.text(kind: .oneWay).hasSuffix("to the finish."))
        XCTAssertEqual(RouteProximity.away(offsetMetres: 2414).text(kind: .oneWay), "About 1.5 mi from this route's mapped line.")
        XCTAssertEqual(RouteProximity.away(offsetMetres: 132).text(kind: .oneWay), "About 130 m from this route's mapped line.")
        for p in [near, .away(offsetMetres: 90), .ambiguous(offsetMetres: 20), .withheld(.weak)] {
            XCTAssertFalse(p.text(kind: .oneWay).lowercased().contains("on the trail"))
            XCTAssertFalse(p.text(kind: .oneWay).lowercased().contains("off route"))
        }
    }

    func testABundledRouteReportsProgressFromItsOwnGeometry() throws {
        let scene = SharedScene.map
        let trace = try XCTUnwrap(scene.hikeRoutes["taft-point"])
        let middle = trace.chainage.point(at: trace.turnaroundMetres / 2)
        guard case .onRoute(let offset, let along, let remaining) = RouteProximity.evaluate(fix: CGPoint(x: middle.x + 8, y: middle.y), accuracy: 12, stale: false,
                                                                                            reducedAccuracy: false, line: trace.points) else { return XCTFail() }
        XCTAssertLessThanOrEqual(offset, 8.0001)
        XCTAssertEqual(along, trace.turnaroundMetres / 2, accuracy: 15)
        XCTAssertEqual(along + remaining, trace.turnaroundMetres, accuracy: 0.5, "an out-and-back is measured on its outward pass only")
    }
}
