import XCTest
import CoreGraphics
import CoreLocation
import UIKit
@testable import PettyFieldGuide

@MainActor
final class LiveLocationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func fix(_ secondsAfterStart: TimeInterval, accuracy: Double = 8, lat: Double = 37.7456, lon: Double = -119.5936) -> LiveFix {
        LiveFix(latitude: lat, longitude: lon, horizontalAccuracy: accuracy, timestamp: t0.addingTimeInterval(secondsAfterStart))
    }

    private func tracking(hosts: Int = 1) -> LiveLocationState {
        var state = LiveLocationState()
        for _ in 0..<hosts { state.hostAppeared() }
        _ = state.start(authorization: .authorized)
        state.received(fix(0), now: t0)
        return state
    }

    // MARK: Session state

    func testNothingRunsOrIsKeptUntilTheControlIsUsed() {
        var state = LiveLocationState()
        state.hostAppeared()
        state.received(fix(0), now: t0)
        XCTAssertEqual(state.phase, .off)
        XCTAssertNil(state.lastFix, "a delivery before the user starts tracking is discarded")
        XCTAssertFalse(state.shouldRunUpdates, "a visible map alone never starts location updates")
    }

    func testFirstUseAsksPermissionThenSearchesOnlyAfterItIsGranted() {
        var state = LiveLocationState()
        state.hostAppeared()
        XCTAssertTrue(state.start(authorization: .notDetermined))
        XCTAssertEqual(state.phase, .awaitingPermission)
        XCTAssertFalse(state.shouldRunUpdates)
        state.authorizationChanged(.authorized)
        XCTAssertEqual(state.phase, .searching)
        XCTAssertTrue(state.shouldRunUpdates)
        state.received(fix(1), now: t0.addingTimeInterval(1))
        XCTAssertEqual(state.phase, .tracking)
    }

    func testDeclinedOrRestrictedPermissionNeverRunsUpdates() {
        var declined = LiveLocationState()
        declined.hostAppeared()
        _ = declined.start(authorization: .notDetermined)
        declined.authorizationChanged(.denied)
        XCTAssertEqual(declined.phase, .denied)
        XCTAssertFalse(declined.shouldRunUpdates)

        var denied = LiveLocationState()
        XCTAssertFalse(denied.start(authorization: .denied), "an earlier refusal is not re-prompted")
        XCTAssertEqual(denied.phase, .denied)

        var restricted = LiveLocationState()
        _ = restricted.start(authorization: .restricted)
        XCTAssertEqual(restricted.phase, .restricted)
        XCTAssertFalse(restricted.shouldRunUpdates)
    }

    func testRevokingPermissionMidSessionStopsAndForgetsThePosition() {
        var state = tracking()
        state.authorizationChanged(.denied)
        XCTAssertEqual(state.phase, .denied)
        XCTAssertNil(state.lastFix)
        XCTAssertFalse(state.shouldRunUpdates)

        var restricted = tracking()
        restricted.authorizationChanged(.restricted)
        XCTAssertEqual(restricted.phase, .restricted)
        XCTAssertNil(restricted.lastFix)
    }

    func testAuthorizationChangesWhileOffDoNotStartTracking() {
        var state = LiveLocationState()
        state.hostAppeared()
        state.authorizationChanged(.authorized)
        XCTAssertEqual(state.phase, .off)
        XCTAssertFalse(state.shouldRunUpdates)
    }

    func testStopClearsTheFixAndIgnoresLateDeliveries() {
        var state = tracking()
        state.stop()
        XCTAssertEqual(state.phase, .off)
        XCTAssertNil(state.lastFix)
        state.received(fix(2), now: t0.addingTimeInterval(2))
        XCTAssertNil(state.lastFix)
    }

    func testRestartingDropsThePreviousSessionsFix() {
        var state = tracking()
        state.stop()
        _ = state.start(authorization: .authorized)
        XCTAssertEqual(state.phase, .searching)
        XCTAssertNil(state.lastFix, "a new session starts searching rather than showing an old dot")
    }

    func testInvalidCachedAndOutOfOrderFixesAreRejected() {
        var state = LiveLocationState()
        _ = state.start(authorization: .authorized)
        state.received(fix(0, accuracy: -1), now: t0)
        XCTAssertEqual(state.phase, .searching, "negative accuracy means iOS has no valid position")
        state.received(fix(-31), now: t0)
        XCTAssertEqual(state.phase, .searching, "a cached fix older than the stale limit is not shown as current")
        state.received(fix(-30), now: t0)
        XCTAssertEqual(state.lastFix, fix(-30), "a fix exactly at the limit is still usable")
        state.received(fix(5), now: t0.addingTimeInterval(5))
        state.received(fix(3), now: t0.addingTimeInterval(6))
        XCTAssertEqual(state.lastFix, fix(5), "an older fix delivered late never replaces a newer one")
    }

    func testStalenessFollowsTheFixTimestampNotTheDeliveryTime() {
        let state = tracking()
        XCTAssertFalse(state.isStale(at: t0.addingTimeInterval(30)))
        XCTAssertTrue(state.isStale(at: t0.addingTimeInterval(30.5)))
        XCTAssertFalse(LiveLocationState().isStale(at: t0.addingTimeInterval(999)), "no fix is not a stale fix")
    }

    func testTransientNoFixErrorKeepsSearchingButOtherFailuresStop() {
        var state = LiveLocationState()
        state.hostAppeared()
        _ = state.start(authorization: .authorized)
        state.failed(.locationUnknown, description: "unknown")
        XCTAssertEqual(state.phase, .searching)
        XCTAssertTrue(state.shouldRunUpdates)

        state.failed(.network, description: "The operation couldn’t be completed.")
        XCTAssertEqual(state.phase, .failed("The operation couldn’t be completed."))
        XCTAssertFalse(state.shouldRunUpdates)

        var denied = tracking()
        denied.failed(.denied, description: "denied")
        XCTAssertEqual(denied.phase, .denied)
        XCTAssertNil(denied.lastFix)
    }

    func testFailureAfterAValidFixLeavesNoPositionDot() {
        var state = tracking()
        state.failed(.network, description: "No signal")
        XCTAssertNil(state.lastFix, "a failed session must not keep showing a fresh 'Your position' dot")
        let model = MapViewModel()
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        model.setScene(MapScene(projection: projection, extent: projection.projectedRect(YosemiteGeo.valleyBounds), roads: [], trails: [], waterLines: [], waterAreas: [],
                                buildings: [], parking: [], pois: [], boundary: [], fireScars: [], contours: [], sources: []))
        model.userFix = MapUserFix(fix: fix(0), stale: false)
        model.userFix = state.lastFix.map { MapUserFix(fix: $0, stale: state.isStale(at: t0)) }
        XCTAssertFalse(model.frameContent.markers.contains { $0.id == "user" })
        XCTAssertNil(model.frameContent.userAccuracy)
    }

    func testUpdatesPauseInTheBackgroundAndWhenNoMapIsVisible() {
        var state = tracking(hosts: 2)
        XCTAssertTrue(state.shouldRunUpdates)
        state.inForeground = false
        XCTAssertFalse(state.shouldRunUpdates, "never tracked in the background")
        state.inForeground = true
        XCTAssertTrue(state.shouldRunUpdates)
        state.hostDisappeared()
        XCTAssertTrue(state.shouldRunUpdates, "moving between two maps keeps the session")
        state.hostDisappeared()
        XCTAssertFalse(state.shouldRunUpdates)
        state.hostDisappeared()
        state.hostAppeared()
        XCTAssertTrue(state.shouldRunUpdates, "an extra disappearance cannot leave the host count negative")
        XCTAssertTrue(state.isOn, "pausing keeps the person's choice; only Stop ends it")
    }

    // MARK: Wording

    func testSummaryReportsTheIOSEstimateAgeAndLimits() {
        var state = tracking()
        XCTAssertEqual(LiveLocationSummary.kind(state, now: t0.addingTimeInterval(4)), .live)
        XCTAssertEqual(LiveLocationSummary.text(state, now: t0.addingTimeInterval(4), onMap: true), "Live GPS · ±8 m iOS estimate · 4 s ago")
        XCTAssertEqual(LiveLocationSummary.text(state, now: t0.addingTimeInterval(4), onMap: false), "Live GPS · ±8 m iOS estimate · 4 s ago · Outside this map's area")
        XCTAssertEqual(LiveLocationSummary.kind(state, now: t0.addingTimeInterval(125)), .stale)
        XCTAssertEqual(LiveLocationSummary.text(state, now: t0.addingTimeInterval(125), onMap: true), "No new fix for 2 min (last ±8 m). You may have moved since.")

        state.received(fix(10, accuracy: 240), now: t0.addingTimeInterval(10))
        XCTAssertEqual(LiveLocationSummary.kind(state, now: t0.addingTimeInterval(10)), .weak)
        XCTAssertTrue(LiveLocationSummary.text(state, now: t0.addingTimeInterval(10), onMap: true).hasPrefix("Weak fix · ±240 m"))

        state.reducedAccuracy = true
        XCTAssertTrue(LiveLocationSummary.text(state, now: t0.addingTimeInterval(10), onMap: true).hasSuffix("Precise Location is off, so iOS reports only an approximate area."))
    }

    func testSummaryStatesForPermissionAndFailure() {
        var state = LiveLocationState()
        XCTAssertEqual(LiveLocationSummary.kind(state, now: t0), .off)
        _ = state.start(authorization: .denied)
        XCTAssertEqual(LiveLocationSummary.kind(state, now: t0), .denied)
        XCTAssertTrue(LiveLocationSummary.text(state, now: t0, onMap: true).contains("Settings"))
        _ = state.start(authorization: .authorized)
        XCTAssertEqual(LiveLocationSummary.kind(state, now: t0), .searching)
        state.failed(.network, description: "No signal")
        XCTAssertEqual(LiveLocationSummary.text(state, now: t0, onMap: true), "Location unavailable: No signal")
        XCTAssertEqual(LiveLocationSummary.age(3 * 3600 + 5), "3 h")
    }

    func testControlLabelsDescribeWhatTheNextTapDoes() {
        XCTAssertEqual(LiveLocationControl.label(isOn: false, following: false), "Start live GPS position")
        XCTAssertEqual(LiveLocationControl.label(isOn: true, following: false), "Centre on my position")
        XCTAssertEqual(LiveLocationControl.label(isOn: true, following: true), "Stop live GPS position")
        XCTAssertEqual(LiveLocationControl.symbol(isOn: true, following: true), "location.fill")
    }

    // MARK: Map overlay

    private func valleyScene() -> MapScene {
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        return MapScene(projection: projection, extent: projection.projectedRect(YosemiteGeo.valleyBounds), roads: [], trails: [], waterLines: [], waterAreas: [],
                        buildings: [], parking: [], pois: [], boundary: [], fireScars: [], contours: [], sources: [])
    }

    func testOverlayDrawsTheReportedAccuracyAndMarksStaleFixes() throws {
        let model = MapViewModel()
        let scene = valleyScene()
        model.setScene(scene)
        model.frameContent = model.withUser(MapFrameContent(markers: [MapMarker(id: "trailhead-x", point: .zero, title: "Trailhead", colorHex: "#2d6c4f")]))

        model.userFix = MapUserFix(fix: fix(0, accuracy: 12), stale: false)
        let marker = try XCTUnwrap(model.frameContent.markers.first { $0.id == "user" })
        XCTAssertEqual(marker.accessibleName, "Your position, accuracy about 12 metres")
        XCTAssertEqual(model.frameContent.userAccuracy, MapAccuracyRing(center: scene.projection.project(fix(0).coordinate), radius: 12, stale: false))
        XCTAssertTrue(model.frameContent.markers.contains { $0.id == "trailhead-x" }, "a secondary map keeps its own markers")

        model.userFix = MapUserFix(fix: fix(0, accuracy: 12), stale: true)
        XCTAssertEqual(model.frameContent.markers.filter { $0.id == "user" }.count, 1, "the position marker is replaced, never duplicated")
        XCTAssertEqual(model.frameContent.markers.first { $0.id == "user" }?.title, "Last GPS fix")
        XCTAssertEqual(model.frameContent.userAccuracy?.stale, true)

        model.userFix = nil
        XCTAssertFalse(model.frameContent.markers.contains { $0.id == "user" })
        XCTAssertNil(model.frameContent.userAccuracy)
    }

    func testPositionsOffTheMapAreRecognisedSoTheMapNeverCentresOnThem() {
        let model = MapViewModel()
        model.setScene(valleyScene())
        XCTAssertTrue(model.isOnMap(CLLocationCoordinate2D(latitude: 37.7456, longitude: -119.5936)), "Yosemite Village")
        XCTAssertFalse(model.isOnMap(CLLocationCoordinate2D(latitude: 37.8742, longitude: -119.3514)), "Tuolumne Meadows is beyond the Valley map")
    }

    func testAnotherFocusEndsFollowing() {
        let model = MapViewModel()
        model.setScene(valleyScene())
        model.followsUser = true
        model.focus(on: CLLocationCoordinate2D(latitude: 37.73, longitude: -119.6), animated: false)
        XCTAssertFalse(model.followsUser, "a search or detail focus must not be yanked back to the GPS dot")
    }
}
