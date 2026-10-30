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

Relief uses two precomputed elevation grids: approximately 20 m over the Valley and 45 m across the surrounding region. Contours derive from the detail grid. The separate 320 × 152 elevation crop drives the sun/shadow preview. Sun shadows do not model clouds, trees or buildings.

A hike is an ordered chain of identified NPS features with explicit endpoint trims, not a union of shared trail names. `content/hikes/hike-routes.json` is the editable definition; `tools/build_hike_routes.py` resolves it into the bundled route pack and [review atlas](hiking-atlas/README.md). Missing features leave a route unavailable rather than joining gaps with invented lines.

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
