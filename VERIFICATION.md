# Verification

## Tested configurations

| Configuration | Result |
|---|---|
| iPhone Air simulator, full XCTest suite, October 29, 2026 | 97 passed, 0 failed or skipped |
| iPad Pro 13-inch (M4) simulator, hiking inspection/map/navigation classes, October 27, 2026 | 21 passed, 0 failed or skipped |
| iPhone 16 Pro, iOS 27.0, October 29, 2026 | Signed device build, signature verification, installation and launch succeeded |

The physical-device development install used a build-only empty entitlements file with an existing wildcard profile; push was unavailable in that install. The source project retains its development push entitlement and automatic, unconfigured signing.

## Public repository cleanup · October 29, 2026

The final cleanup passed all 97 iOS tests, all 11 server tests and the bundled JSON/model validation. Production changes were limited to comments; a comparison against the pre-cleanup snapshot found no executable source changes. No new compiler warnings were introduced. The publication set excludes credentials, local runtime data, research downloads, generated Xcode files and internal working notes.

## Coverage

The iOS suite covers shuttle direction, service dates and transfers; Pacific calendar recurrence and DST; persistence, backup versions and merge semantics; condition acquisition/expiry; search and deep links; map geometry, hit testing, camera fit and route selection; complete hike chains, interpolation, return landmarks and approximate grade; linked map/profile state; constrained card layout; and compact/regular navigation lifecycles.

Earlier simulator checks exercised map categories, layers, search selection, grouped markers, water/ice, programs, parked-car placement, hike variants, route fit, detail navigation and tablet layouts. The newest focused map and terrain inspector still need a complete manual touch/rotation review. Hosted component tests are not a substitute for that review.

## Reproduce

Generate the project with `cd ios && xcodegen generate`, then from the repository root:

```sh
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault xcodebuild \
  -project ios/EnveYosemite.xcodeproj -scheme EnveYosemite \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Choose an installed simulator name from `xcrun simctl list devices available`. To repeat tablet component coverage, use an iPad destination and add:

```sh
-only-testing:PettyFieldGuideTests/HikingInspectionTests \
-only-testing:PettyFieldGuideTests/HikingMapTests \
-only-testing:PettyFieldGuideTests/SectionNavigationTests
```

Server checks:

```sh
cd server
npm run check
```

Bundled JSON/model validation:

```sh
python3 -I tools/check_models.py
```

Builds have one existing tool warning: AppIntents metadata extraction is skipped because the app does not depend on AppIntents. No new compiler warnings are accepted.

## Not verified

Physical-device GPS, APNs delivery, deployed live feeds, iOS 17 runtime behavior, long offline field sessions, and extreme split-view/text-size combinations remain unverified. Missing server credentials are not replaced with fabricated live results.
