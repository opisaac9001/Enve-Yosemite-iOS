# Sources, licences and attribution

Enve Yosemite bundles public datasets, published park documents and original guide text. Source identities, snapshot dates and attribution are retained below and in the bundled records. The original Yosemite Field Desk project was a behavioral and factual reference; its application code and styling are not included. Third-party material retains its own terms. No protection is claimed in original U.S. Government works.

## Bundled geometry and inventories

| Pack | Publisher | Licence | Snapshot | Notes |
|---|---|---|---|---|
| `buildings.geojson`, `parking.geojson`, `pois.geojson`, `roads.geojson`, `trails.geojson` | National Park Service, NPS Public GIS NationalDatasets (Buildings, ParkingLots, POIs, Roads, Trails), `UNITCODE='YOSE'` | US Government work, public domain | fetched 2026-09-21 | Positional accuracy mostly "Unknown"; orientation data, not survey data |
| `trails.geojson` additions: NPS OBJECTIDs 20072 and 22688 (John Muir Trail through Little Yosemite Valley) | Same NPS_Public_Trails_Geographic service, queried for `TRLNAME IN ('John Muir Trail','Half Dome Trail')` in envelope −119.535,37.715,−119.495,37.755 | public domain | fetched 2026-10-27 (`content/hikes/trails-extra-lyv.geojson`, recorded in `map-manifest.json` under `appended`) | The Valley envelope query omits them; they complete the Half Dome routes. Vertex-identical to NPS Yosemite GIS YOSE_Trails geometry |
| `hike-routes.json` | Derived: ordered chains of the NPS trail features above, resolved by `tools/build_hike_routes.py` from `content/hikes/hike-routes.json` (reviewed against the NPS Vernal/Nevada, Yosemite Falls, Valley Loop and Cook's Meadow trail maps) | public domain inputs; original text | generated 2026-10-27 | Route traces, milestones, GIS lengths; published distances remain the NPS figures in `trails.json` |
| `park-roads.geojson`, `park-pois.geojson` | NPS Public GIS NationalDatasets | public domain | fetched 2026-09-21 | Park-wide schematic |
| `park-boundary.geojson` | NPS administrative boundary | public domain | edit date 2025-09-19 | |
| `fire-scars.geojson` | CAL FIRE Fire and Resource Assessment Program (FRAP), California Historic Fire Perimeters | public record (State of California) | snapshot in pack metadata | Historical outlines only |
| `campsites.geojson` | Recreation.gov RIDB API, facilities/{id}/campsites | US Government data (RIDB terms) | fetched 2026-10-22 | Inventory positions, never availability |
| `campground-context.geojson` | NPS Yosemite GIS (roads, restroom points) | public domain | fetched 2026-10-22 | |
| `elevation-valley.json` | Mapzen/Tilezen terrarium tiles on AWS Open Data (USGS 3DEP derived), zoom 13 | Terrain tiles: public domain sources (USGS 3DEP); Mapzen tiles under their open terms | fetched 2026-09-21 | 320×152 cells, 0.1 m vertical scale; sun/shadow preview only |
| `elevation-basemap.json` (relief detail tier) | Mapzen/Tilezen Terrarium terrain tiles on AWS Open Data (`s3://elevation-tiles-prod/terrarium`, zoom 13; US coverage derived from USGS 3DEP/NED), see https://registry.opendata.aws/terrain-tiles/ and https://github.com/tilezen/joerd/blob/master/docs/attribution.md | Public bucket, no account; USGS data public domain; attribution to Mapzen/Tilezen and USGS kept in the asset metadata and the in-app key | fetched 2026-10-27 (35 tiles, 4.25 MB; z13 x 1370–1376 · y 3165–3169) | 1189×944 samples at 20.0 m (samples on both edges), bounds 37.65–37.82 N / −119.76–−119.49 E (Valley extent + 0.04°), bilinear resample from Web Mercator onto a regular WGS84 grid, 0.1 m vertical scale, 3.0 MB. Reproducible with `tools/prepare_basemap_terrain.py --zoom 13 --cell 20`; the detail shaded relief and 50 m contours derive from it. Positional accuracy is the tiles'; no survey claim |
| `elevation-region.json` (relief background tier) | Same Terrarium source at zoom 12 | As above | fetched 2026-10-27 (72 tiles, 9.62 MB; z12 x 683–690 · y 1579–1587) | 1194×1358 samples at 45.0 m, bounds 37.46–38.01 N / −119.93–−119.32 E (≈54 × 61 km around the Valley extent, sized for the camera's zoom floor on phones and iPads), 4.33 MB. Drawn beneath the detail tier; both tiers feather at their edges. `tools/prepare_basemap_terrain.py --zoom 12 --cell 45 …` |
| `waterways.geojson` | USGS National Hydrography Dataset (flowlines and water bodies, Merced River and tributaries) | public domain | as fetched by the reference pipeline | Attributes keep NHD ids |
| `transit.json` | NPS GTFS feed `yosemite-valley-shuttle.zip` (feed 20260501) and Mariposa Grove shuttle (20260504) | public (NPS) | fetched 2026-09-26 | Interpolated intermediate stop times |
| `water-ice.json` | © OpenStreetMap contributors | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) — https://www.openstreetmap.org/copyright | checked 2026-09-25 | Water and ice records; ODbL attribution shown in-app |
| `dump-stations.json` | NPS records + © OpenStreetMap contributors | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) | checked 2026-10-02 | |
| Explorer packs (optional download) | NPS Yosemite GIS ArcGIS services (YOSE_Trails, YOSE_Roads, YOSE_Buildings, YOSE_Structures, YOSE_Parking, NPS_Public_POIs) | public domain | fetched 2026-10-22; regenerable with `server/scripts/fetch-gis-packs.mjs` | Served by the companion server |

## Documents (bundled PDFs)

| File | Publisher | Source page |
|---|---|---|
| Yosemite Guide 51.8 (Sep 23–Nov 24, 2026) | National Park Service | https://www.nps.gov/yose/planyourvisit/guide.htm |
| Yosemite Accessibility Guide (2022) | National Park Service | https://www.nps.gov/yose/planyourvisit/accessibility.htm |
| Park & campground map | National Park Service | https://www.nps.gov/yose/planyourvisit/maps.htm |
| Wilderness trailheads map (2022, file 2026) | National Park Service | https://www.nps.gov/yose/planyourvisit/trailheads.htm |
| Junior Ranger adapted activities (2021) | National Park Service · Yosemite Conservancy | https://www.nps.gov/yose/learn/kidsyouth/junior-ranger.htm |

The PDFs retain their publisher credits and any third-party rights. NPS-authored government material is generally public domain, but NPS hosting alone does not make every image or contribution public domain; see the [NPS ownership notice](https://www.nps.gov/aboutus/disclaimer.htm). No endorsement or rights to NPS trademarks are claimed. SHA-256 digests are recorded in `documents.json` and verified by the in-app pack check.

## Curated content (places, trails, campgrounds, permits, contacts, events, regions, webcams)

Facts (names, coordinates, phone numbers, hours, dates, fees, URLs, review dates) come from the official pages cited on each record: NPS Yosemite pages and the NPS Developer API, Yosemite Hospitality (travelyosemite.com), Yosemite Conservancy, Recreation.gov, YARTS, AFDC (EV stations), county and venue event listings, and NPS public GIS features. Every record keeps its `sources` list and `checked` date and is displayed with them. Guide prose is maintained in the original wording overlays under `content/rewrites/`; factual names, dates, hours and source records retain their published values.

Webcam links point to provider pages only: Yosemite Conservancy (usage agreement applies), NPS webcam pages, and ALERTCalifornia (imagery CC BY-NC-ND 4.0, credited “ALERTCalifornia | UC San Diego”). No imagery is embedded.

## Live feeds (companion server)

NWS api.weather.gov (public), EPA Envirofacts UV (public), Open-Meteo GFS and air-quality APIs (CC BY 4.0, non-commercial free tier), USGS NWIS (public), Caltrans CWWP2 (public), NOAA HMS smoke analysis (public), NIFC WFIGS (public), CAL FIRE incidents (public), InciWeb (public), NPS Developer API (key required), AirNow (key required, data from EPA/partner agencies), NASA FIRMS (map key required; VIIRS data from NASA/NOAA).

## Park facts shown while loading

Original phrasings of statements on nps.gov/yose pages; each fact links to its NPS page.
