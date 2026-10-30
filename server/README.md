# Enve Yosemite — companion server

Small Node 22+ server (no dependencies) that aggregates public condition feeds for the iOS app, hosts the optional GIS explorer packs, stores suggestions with opaque receipts, and registers APNs device tokens.

The app works fully offline without it. Enter the server address in the app under Settings › Conditions server to enable live refresh.

## Run

```bash
cd server
cp .env.example .env     # fill in keys you have; everything is optional
npm run check            # syntax check + unit tests
npm start                # http://127.0.0.1:8787
```

Put it behind HTTPS (reverse proxy) before exposing it beyond a LAN; the app allows plain HTTP for LAN use.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/weather?point=valley` | NWS hourly + observation + alerts, EPA UV, Open-Meteo visibility/snow/AQI for one of seven forecast points |
| GET | `/api/fire-risk` | Fire planning heuristic with inputs, NWS fire weather (FWF CAZ592), NPS alerts, NPS fire-restrictions page |
| GET | `/api/smoke` | NPS air monitors, AirNow (keyed), NOAA HMS plumes, NIFC incidents + perimeters, CAL FIRE, InciWeb links, FIRMS VIIRS (keyed), incident tracking |
| GET | `/api/seasonal-risks` | NPS alerts (keyed), USGS Pohono Bridge gauge, Caltrans chain controls |
| GET | `/api/nps-programs` | NPS events (next 45 days) and visitor-centre hours (keyed) |
| GET | `/api/conditions` | NPS conditions page (road table, roadwork, trail closures), road events + alerts (keyed), wilderness page |
| GET | `/api/updates` | Channel revisions for topic tracking, `pushReady` |
| POST | `/api/suggestions` | `{name?, title?, text (≤250), layout?, proof?}` → receipt |
| POST | `/api/suggestions/status` | `{receipts:[{receipt,name}]}` → replies |
| POST | `/api/push/register` / `/api/push/unregister` | APNs token with topic preferences |
| GET | `/data/explorer/…` | GIS packs and `catalog.json` |

Every feed section carries `state` (`ready`, `unavailable`, `unknown`), `checkedAt` and, where the upstream publishes one, `sourceTime`. Missing keys produce `unavailable` with the reason; nothing is fabricated. The NPS air-monitor JSON returned HTTP 404 during development and is reported as such.

## Keys and credentials (operator-supplied)

- `NPS_API_KEY` — https://www.nps.gov/subjects/developer/get-started.htm
- `AIRNOW_API_KEY` — https://docs.airnowapi.org/
- `FIRMS_MAP_KEY` — https://firms.modaps.eosdis.nasa.gov/api/area/
- APNs: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8_PATH`, `APNS_BUNDLE_ID` (defaults to the installed app's unchanged bundle ID `dev.petty.fieldguide`). Token-based auth (ES256 JWT over HTTP/2). The app must also be signed with a team that has the push capability. Until all of this exists, `/api/updates` reports `pushReady: false` and the app shows push as unavailable.

## Automatic alerts

Every refresh (on request, on the `REFRESH_MINUTES` timer, or `npm run refresh`) hashes each feed's content with volatile fields removed (`feed-revisions.json`). A channel's revision combines the hashes of every feed reporting into it (`seasonal` = seasonal + conditions), so refreshing unchanged feeds in any order never moves it. When a channel's content really changes and APNs is configured, the server sends one alert per registered token subscribed to that channel (`weather`, `fire`, `smoke`, `seasonal`, `events`) with an `enveyosemite://section/…` deep link that the app opens on tap (the app also still accepts legacy `pettyfieldguide://` links). Without APNs credentials the revision still moves (so in-app tracking works) and nothing is sent. `npm run send-push` remains available for manual announcements.
- `CALTRANS_CC_URL_TEMPLATE` — the CWWP2 chain-control JSON per district. The default pattern is documented at https://cwwp2.dot.ca.gov/documentation/chain-controls.html; verify it against the current documentation if districts report `unavailable`.

## Scripts

- `npm run refresh` — fetch every feed once (also runs every `REFRESH_MINUTES` while the server is up).
- `npm run fetch-gis` — regenerate the six explorer packs and `catalog.json` from NPS ArcGIS services into `EXPLORER_DIR`.
- `npm run reply -- <receipt> "text" [--close]` — answer a suggestion.
- `npm run send-push -- <channel> "title" "body" [url]` — send an alert to tokens subscribed to a channel (`weather`, `fire`, `smoke`, `seasonal`, `events`, `app`).

## Data on disk (`DATA_DIR`)

`cache.json` (latest feed payloads), `feed-revisions.json` (per-feed content hashes), `revisions.json` (update channels), `tracking.json` (incident history), `suggestions.json`, `push-tokens.json`. All writes are atomic. No analytics, no request logging of client identifiers.
