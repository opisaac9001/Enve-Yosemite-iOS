# Architecture

Enve Yosemite is a Swift 6 / SwiftUI app with a custom offline map renderer and an optional Node.js companion server. The app has no third-party Swift dependencies.

## App structure

| Area | Responsibility |
|---|---|
| `App/` | Adaptive navigation, deep links, appearance, settings and location tools |
| `Content/` | Codable pack models and the main-actor content store |
| `Geo/` | GeoJSON decoding, projection and spatial helpers |
| `Map/` | Camera, scene construction, Core Graphics rendering, hit testing and map controls |
| `Hiking/` | Ordered route chains, distance interpolation, landmarks, approximate terrain sampling, hike discovery and linked inspection |
| `Saved/`, `Trip/` | Personal records, backup import/export and trip preparation |
| Feature folders | Places, campsites, search, transit, events, documents, permits, regions and conditions |
| `Resources/` | Bundled JSON, GeoJSON, elevation grids and PDFs |

SwiftUI owns navigation and controls. UIKit hosts the map canvas and the elevation scrubber. Asynchronous work uses structured concurrency, with UI state isolated to the main actor.

## Offline map

The renderer projects WGS84 coordinates into a local equirectangular meter grid, builds reusable paths from the bundled geometry, and draws them with Core Graphics. Pan, pinch and double-tap update a camera rather than rebuilding source geometry. Labels and markers are prioritized against each other and the visible controls; grouped markers retain access to overlapping records.

The Map tab draws one scene (`MapSceneBuilder`) in a single Valley-centred projection, so the whole park and the Valley's streets are one continuous map. The Valley packs keep their detail; park-wide NPS supplements (`park-roads`, `park-buildings`, `park-parking`, `park-pois`) hold only features whose OBJECTID is not already in a Valley pack, `park-trails.geojson` contributes the trail features the Valley pack lacks, and `park-water.geojson` the NHD features `waterways.geojson` lacks, so nothing is drawn twice. `park-names.geojson` supplies GNIS landform labels, shown from a zoom that depends on class and summit elevation; region names label the overview.

Relief comes from four precomputed grids drawn coarsest first, each feathering into the one beneath: USGS 3DEP at about 800 m out to roughly 300 km from the park (open ocean beyond 3DEP coverage is a recorded gap drawn transparent), USGS 3DEP at about 250 m around the park, USGS 3DEP at about 30 m (1/3200°) over the park bounds, and the 20 m Valley grid. Each `ReliefLayer` keeps per-cell shade and elevation-tint bytes in a 2× pyramid, every level shaded from its own averaged elevations with slightly more vertical exaggeration; the renderer draws only the visible 256-pixel tiles of the level that suits the zoom, colouring each tile for the current appearance once and caching it. Contours come from the Valley grid (50 m) and, outside it, the park grid (200 m). The separate 320 × 152 elevation crop drives the sun/shadow preview. Sun shadows do not model clouds, trees or buildings. Historical fire perimeters are part of the scene but drawn and tappable only when a map sets `showFireScars` (the Fire map).

A hike is an ordered chain of identified NPS features with explicit endpoint trims, not a union of shared trail names. `content/hikes/hike-routes.json` is the editable definition; `tools/build_hike_routes.py` resolves it into the bundled route pack and [review atlas](hiking-atlas/README.md). Missing features leave a route unavailable rather than joining gaps with invented lines.

Hikes outside the Valley come from `park-hikes.json`, which `tools/build_park_hikes.py` writes and which merges into the trail list at load. Each route names the pack it was traced on: Valley routes on `trails.geojson`, routes marked `"geometry": "park"` on `park-trails.geojson`. Both resolve on the one map's trail list (the Valley pack's features are vertex-identical copies of the same NPS ids) and profile against the 20 m Valley grid or the 3DEP park grid respectively. A hike without a complete reviewed chain shows the regional map with its start pin and no highlighted route, and on the Map tab selects its trailhead.

`MapTabScreen` hosts the one map and hands every map request (links, searches, "show on map") to `MapViewModel.focus(on:)`: places, campsites in any campground, hike routes, untraced hikes (their trailhead), coordinates (a labelled pin, or the parked car when it matches), regions and the whole park. `MapCoverage` says whether a request can be shown at all: anything inside the park bounds. The camera's zoom floor is the smaller of 0.8 × a whole-view fit of the extent and the scale that fits the park boundary between the chrome, so "Fit park" is always reachable; `terrainFloor(viewSize:)` raises it only where that view, centred on the pan clamp (extent plus 2 km), would reach past the outer tier's unfaded relief. The outer tier is sized so that never happens on supported phone and iPad layouts. The map still opens on the Valley visitor core. Trailheads, campgrounds and region points beyond the Valley come from `ParkMapView.markers`, filtered by the matching place categories.

With live GPS on, a map that highlights a route compares each fix with that route's one-pass line (`RouteProximity`). Figures are withheld for stale, approximate (Precise Location off) or worse-than-±50 m fixes, reduced to a distance from the line beyond 75 m (or the accuracy radius), and withheld as ambiguous where stretches inside the accuracy band are far apart along the route. Nothing alerts or records.

Hike notices group by the most specific reason: a curated pattern or a distinctive route name, a road the trailhead is reached by, then the region. Only unexpired snapshots contribute. Trailhead sun times come from the on-device NOAA solar equations for the selected Pacific calendar day.

Each resolved route stores cumulative traveled distance. Out-and-back routes include the return pass, while loops retain distinct start/end landmarks. The map cursor and elevation readout share one inspected distance; scrubbing does not change the camera. Published NPS distances and elevation gains remain separate from GIS length and sampled terrain values.

## Content and storage

The base app bundles content, geometry and five park PDFs. XcodeGen copies the `Content`, `Geo` and `Documents` folders directly to the app bundle root. Do not copy a root folder named `Resources`: that causes CFBundle to infer the wrong bundle layout.

Curated prose overlays are kept under `content/rewrites/`. The initial import pipeline (`tools/build_content.py`) needs local factual snapshots under the ignored `research/` directory; those snapshots are not needed to build or run the app. Checked-in resources are the build inputs. Route and terrain preparation tools can regenerate their specific derived packs. [Sources and terms](SOURCES.md) describe the datasets.

`SavedStore` writes private records to Application Support with serialized atomic writes. Explicit backups carry saved data and supported settings; import validates the format and merges newer records. Public share links exclude private notes, car and campsite coordinates. Feedback receipts are held in Keychain.

Conditions cache acquisition time separately from retrieval time, so re-serving an old response cannot make it fresh. Snapshots expire after 48 hours. Optional GIS downloads verify checksums and replace packs atomically, preserving the last complete copy after a failed download.

## Companion server

The dependency-free Node.js 22+ server aggregates public weather, fire, smoke, road and park feeds; serves optional GIS packs; and supports feedback receipts, update revisions and APNs registration. Each feed reports availability and timestamps. Operator credentials are read from environment variables, not bundled in the app.

The server address is configured in the app. It is unnecessary for base maps, documents, saved records, hiking data and the offline shuttle planner. See [server setup](../server/README.md) for endpoints and credential requirements.

## Compatibility identifiers

The public project/scheme and display name are `EnveYosemite` / Enve Yosemite. The app was originally named petty: Field Guide; internal identities stay stable so installed data survives updates:

- Target/module/source folder and product: `PettyFieldGuide`.
- App bundle ID: `dev.petty.fieldguide`; test bundle ID: `dev.petty.fieldguide.tests`.
- Application Support location, preferences, notification names and Keychain identifiers.
- Backup format marker: `petty-field-guide-backup`.
- Incoming URL schemes: `enveyosemite://` and legacy `pettyfieldguide://`. New links emit the Enve scheme.

Do not rename storage identities as a cosmetic cleanup.
