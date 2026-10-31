# Verification

Last verified October 30, 2026.

## Results

| Check | Result |
|---|---|
| `xcodegen generate` | Succeeded |
| Full XCTest suite, iPhone Air simulator | 156 passed, 0 failed |
| Build, iPad Pro 13-inch (M4) simulator | Succeeded |
| Bundled JSON/model validation (`tools/check_models.py`) | 0 mismatched packs |
| Hike route validation (`tools/build_hike_routes.py --check`) | 43 routes valid |
| Map pack manifest | All 30 checksums match the bundled files |
| Server checks (`npm run check`), October 29, 2026 | 11 passed; not rerun after later iOS-only changes |
| Physical iPhone 16 Pro, iOS 27.0 | Signed development build installed and launched |
| Xcode Cloud post-clone script on a fresh clone, then full XCTest suite, October 31, 2026 | Project generated; 156 passed, 0 failed. Not yet run on Xcode Cloud |

Builds and tests emit one existing tool warning: AppIntents metadata extraction is skipped because the app does not depend on AppIntents. No other warnings are accepted.

The physical-device install used build-only empty entitlements, so push notifications were unavailable on that install. The source project keeps its development push entitlement and automatic, unconfigured signing.

## Simulator checks

iPhone Air:

- The map opened on Valley detail with relief. Fit park showed park-wide terrain and rivers in light appearance; dark appearance was also checked.
- The finder framed Wawona. The May Lake hike was selected and its route drawn and fitted.
- Live GPS: the permission prompt, starting, simulated movement with following, a stale fix and Stop. With the May Lake route sheet open and a simulated fix at the trailhead, the banner showed the near-route distance and progress text.
- The night-vision toggle in Settings, in both directions.

iPad Pro 13-inch (M4):

- Fit park in dark appearance; earlier, Wawona and Tuolumne framing and the Wawona regional map with live position.
- The May Lake route sheet with simulated GPS at the trailhead, and the distance from the mapped line after moving the location away.
- The trailhead daylight card, including advancing one day.
- The wording shown when no conditions snapshot is saved.
- The map with night vision enabled, before the park-wide relief was added.

Simulator tap automation was unreliable in places; the checks above are the ones actually exercised.

## Test coverage

The iOS suite covers:

- Shuttle direction, service dates and transfers; Pacific calendar recurrence and DST, including trailhead daylight across the November clock change.
- Persistence, backup versions, legacy backup import and merge semantics; condition acquisition, 48-hour expiry and missing snapshots; hike notice grouping and matching.
- Search, both `enveyosemite://` and legacy `pettyfieldguide://` deep links.
- The continuous map: pack merging without duplicates, projection accuracy, relief decoding and tier coverage at the zoom floor on phone and iPad layouts, hit testing, camera fit and route, place, pin and parked-car focus.
- Hike route chains, builder lengths, interpolation, landmarks, terrain profiles and linked map/profile state.
- Live location: no collection before the control is used, permission states, fix rejection, the 30-second stale boundary, background pausing, and route-relative figures withheld for stale, approximate or weak fixes.
- Constrained card layout and compact/regular navigation lifecycles.

These are unit and hosted component tests. They do not replace manual touch, rotation or field review.

## Reproduce

From the repository root:

```sh
(cd ios && xcodegen generate)

xcodebuild \
  -project ios/EnveYosemite.xcodeproj -scheme EnveYosemite \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test

xcodebuild \
  -project ios/EnveYosemite.xcodeproj -scheme EnveYosemite \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Choose installed simulator names from `xcrun simctl list devices available`.

Data and server checks:

```sh
python3 -I tools/check_models.py
python3 -I tools/build_hike_routes.py --check
(cd server && npm run check)
```

## Known limitations

- 17 park hikes (20 published variants) have no verified full route trace. They show their trailhead and a labelled regional map. Soda Springs, Harden Lake and Young Lakes were traced but rejected as incomplete.
- No field testing: GPS accuracy outdoors, behavior under cliffs and tree cover, on switchbacks and loop stems, after screen lock, with Precise Location off, battery use over long sessions, park map load time on a device and long offline sessions are unverified.
- Maps and content are bundled for offline use. Live condition feeds require the companion server; no deployed server or live feed has been verified, and missing credentials are never replaced with fabricated results. APNs delivery is unverified.
- Map UI not yet exercised: red night vision over the park-wide relief; the outer terrain tier and its ocean edge at the zoom floor; landscape phone and iPad split view; label density across zooms; pan/zoom smoothness at regional zoom and in Debug; region, campground, town and pin cards and cluster pick lists; search and deep links on the device UI, including the legacy scheme; untraced-hike trailheads; high-country campsite numbers; a parked car beyond the Valley; the water guide's Mariposa Grove links; the Fire, region and hike mini maps.
- Hike UI not yet exercised: notices from a saved snapshot, including stale and expired snapshots and list badges; park routes and regions other than those listed above.
- Accessibility: VoiceOver and large Dynamic Type on the newer map controls, cards and route sheet are unverified.
- iOS 17 runtime behavior and extreme split-view/text-size combinations are unverified.
