# Feature status

The app is in development. “Implemented” describes available behavior, not certification for field navigation. Content counts and official rules are dated snapshots; individual records show their sources.

| Area | Available | Dependency or limit |
|---|---|---|
| Maps | Offline Valley and park maps, relief, contours, buildings, roads, trails, categories, grouped markers, campsites, search and sun/shadow preview | Geometry and terrain have source accuracy limits; this is not turn-by-turn navigation |
| Hikes | 12 hikes, 19 explicit route chains, complete highlighting and fit, variant selection, focused/all-places presentation, landmarks and linked elevation inspection | Approximate terrain samples and mapped distances are separate from published NPS figures; latest inspector touch QA remains pending |
| Places | 253 records, search and filters, details, sources, accessibility, contacts, water/ice guide and map links | Inventory positions and historical reports do not establish availability |
| Camping | 13 campground guides, numbered campsite search/maps, saved campsite | No reservation inventory or booking service |
| Saved records | Favorites, notes, parked car, campsite, JSON backup export/import, legacy backup compatibility | Stored locally; private notes and pins are excluded from public share links |
| Search | Places, campsites, contacts, hikes, events, documents and planning topics | Distance tools ask for location when invoked |
| Transit | Offline GTFS schedules, directed routes, transfers, service dates and stop timetables | Scheduled times; no live arrival or timed walking estimates |
| Events | 149 curated listings, calendar, recurrence, filters, saved views and share links | Live NPS listings require the companion server and an NPS API key |
| Permits and regions | Intent-based permit guides, six region guides, approaches and official links | Rules and seasonal access must be checked with the cited operator |
| Documents | Five bundled PDFs, PDFKit reader and sharing | Editions are dated; document credits remain with their publishers |
| Conditions | Weather, fire, smoke, roads, seasonal checks and NPS notices, with source/fetch dates and 48-hour expiry | Operator-run server required; several upstreams need keys and can be unavailable |
| GIS explorer | Optional six-pack catalog, checksum validation, atomic replacement, search and attribute inspection | Server-hosted packs; interrupted downloads restart rather than resume |
| Updates and feedback | Topic tracking, unread state, local drafts, explicit submission, private receipts and reply polling | Server required; push delivery also needs APNs credentials and compatible app signing |
| Appearance and access | System/light/dark, text and map sizing, VoiceOver, phone/tablet navigation | Extreme split-view layouts and uninterrupted field use remain unverified |

## Known limits

- Bundled base packs are updated with the app. Repairing a damaged bundled resource requires reinstalling or updating the app.
- Optional GIS downloads keep the previous valid pack on failure, but do not resume partial downloads.
- Building callouts use centroid anchors. Relief covers the Valley and surrounding region, with faded edges at very wide views.
- Caltrans chain-control URLs are configurable; the upstream returned errors during initial verification. An unavailable feed is displayed as unavailable.
- Live feeds, notification delivery, physical-device GPS and long offline field use have not been verified end to end.
- There is no GPS recording, custom route planner or background navigation service.

Implementation details are in [architecture](ARCHITECTURE.md), source terms in [attribution](SOURCES.md), and test coverage in [verification](../VERIFICATION.md).
