import { fetchJSON, fetchText, sourced, nowISO } from "../lib/http.js";
import { env } from "../lib/env.js";
import { haversineMiles, bearingName, pointInRing, VALLEY, PARK_BBOX } from "../lib/geo.js";
import { FORECAST_POINTS } from "../lib/points.js";
import { readJSON, writeJSON } from "../lib/store.js";

const NPS_MONITORS = "https://www.nps.gov/featurecontent/ard/currentdata/json/yose.json";
const NIFC_BASE = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services";
const CALFIRE_URL = "https://incidents.fire.ca.gov/umbraco/api/IncidentApi/List?inactive=false";
const INCIWEB_RSS = "https://inciweb.wildfire.gov/incidents/rss.xml";
const INCIDENT_RADIUS_MILES = 150;
const HOTSPOT_WINDOW_HOURS = 48;

/** Parses NOAA HMS smoke KML into density polygons (lon/lat rings). */
export function parseHMSKML(xml) {
  const polygons = [];
  for (const pm of xml.matchAll(/<Placemark>([\s\S]*?)<\/Placemark>/g)) {
    const body = pm[1];
    const density = /<(?:name|SimpleData name="Density")>\s*(Light|Medium|Heavy)\s*</i.exec(body)?.[1] ?? (/Heavy/i.test(body) ? "Heavy" : /Medium/i.test(body) ? "Medium" : "Light");
    const start = /<SimpleData name="Start">([^<]+)</.exec(body)?.[1] ?? null;
    const end = /<SimpleData name="End">([^<]+)</.exec(body)?.[1] ?? null;
    const rings = [...body.matchAll(/<coordinates>([\s\S]*?)<\/coordinates>/g)].map((m) => m[1].trim().split(/\s+/).map((pair) => pair.split(",").slice(0, 2).map(Number)).filter((p) => p.length === 2 && p.every((n) => !Number.isNaN(n))));
    if (!rings.length || rings[0].length < 3) continue;
    polygons.push({ density, start: hmsTime(start), end: hmsTime(end), ring: rings[0], holes: rings.slice(1) });
  }
  return polygons;
}

function hmsTime(s) {
  // HMS uses "YYYYDDD HHMM" (day of year) in Start/End fields.
  const m = /^(\d{4})(\d{3})\s+(\d{2})(\d{2})$/.exec(s ?? "");
  if (!m) return s ?? null;
  const d = new Date(Date.UTC(Number(m[1]), 0, 1));
  d.setUTCDate(Number(m[2]));
  d.setUTCHours(Number(m[3]), Number(m[4]));
  return d.toISOString();
}

function bboxIntersects(ring) {
  return ring.some(([lon, lat]) => lon >= PARK_BBOX.west - 1 && lon <= PARK_BBOX.east + 1 && lat >= PARK_BBOX.south - 1 && lat <= PARK_BBOX.north + 1);
}

async function hmsPlumes() {
  const now = new Date();
  const attempt = async (date) => {
    const y = date.getUTCFullYear(), m = String(date.getUTCMonth() + 1).padStart(2, "0"), d = String(date.getUTCDate()).padStart(2, "0");
    const url = `https://satepsanone.nesdis.noaa.gov/pub/FIRE/web/HMS/Smoke_Polygons/KML/${y}/${m}/hms_smoke${y}${m}${d}.kml`;
    const { text } = await fetchText(url, { accept: "application/vnd.google-earth.kml+xml, text/xml, */*", timeoutMs: 40_000 });
    return { url, date: `${y}-${m}-${d}`, polygons: parseHMSKML(text) };
  };
  const result = await sourced("hms-smoke", "NOAA HMS satellite smoke plumes", "https://www.ospo.noaa.gov/Products/land/hms.html", async () => {
    try {
      const today = await attempt(now);
      return { value: today, sourceTime: `${today.date}T00:00:00Z` };
    } catch (error) {
      if (error.status !== 404) throw error;
      const yesterday = await attempt(new Date(now.getTime() - 86_400_000));
      return { value: yesterday, detail: "Today's analysis not published yet; showing the previous UTC day", sourceTime: `${yesterday.date}T00:00:00Z` };
    }
  });
  return result;
}

async function nifcIncidents() {
  const url = `${NIFC_BASE}/WFIGS_Incident_Locations_Current/FeatureServer/0/query?where=1%3D1&outFields=IncidentName,IncidentSize,PercentContained,IrwinID,UniqueFireIdentifier,FireDiscoveryDateTime,ModifiedOnDateTime_dt,IncidentTypeCategory,POOCounty,POOState&geometry=${PARK_BBOX.west - 2},${PARK_BBOX.south - 2},${PARK_BBOX.east + 2},${PARK_BBOX.north + 2}&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outSR=4326&f=geojson`;
  return sourced("nifc-wfigs", "NIFC WFIGS current incident locations", "https://data-nifc.opendata.arcgis.com/", async () => {
    const { data } = await fetchJSON(url);
    const items = (data.features ?? []).map((f) => {
      const p = f.properties;
      const [lon, lat] = f.geometry?.coordinates ?? [null, null];
      return { id: p.UniqueFireIdentifier ?? p.IrwinID, name: p.IncidentName, source: "NIFC", type: p.IncidentTypeCategory ?? null, acres: p.IncidentSize ?? null, percentContained: p.PercentContained ?? null, discoveredAt: p.FireDiscoveryDateTime ? new Date(p.FireDiscoveryDateTime).toISOString() : null, updatedAt: p.ModifiedOnDateTime_dt ? new Date(p.ModifiedOnDateTime_dt).toISOString() : null, latitude: lat, longitude: lon, county: p.POOCounty ?? null, irwinId: p.IrwinID ?? null, url: null, inciwebUrl: null };
    }).filter((i) => i.latitude != null);
    return { value: items };
  });
}

async function nifcPerimeters() {
  const url = `${NIFC_BASE}/WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query?where=1%3D1&outFields=poly_IncidentName,poly_GISAcres,attr_PercentContained,poly_IRWINID,attr_UniqueFireIdentifier,attr_ModifiedOnDateTime_dt&geometry=${PARK_BBOX.west - 2},${PARK_BBOX.south - 2},${PARK_BBOX.east + 2},${PARK_BBOX.north + 2}&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outSR=4326&geometryPrecision=4&f=geojson`;
  return sourced("nifc-perimeters", "NIFC WFIGS current fire perimeters", "https://data-nifc.opendata.arcgis.com/datasets/nifc::wfigs-current-interagency-fire-perimeters", async () => {
    const { data } = await fetchJSON(url, { timeoutMs: 40_000 });
    const items = (data.features ?? []).map((f) => {
      const p = f.properties;
      const rings = f.geometry?.type === "Polygon" ? [f.geometry.coordinates[0]] : f.geometry?.type === "MultiPolygon" ? f.geometry.coordinates.map((poly) => poly[0]) : [];
      return { id: p.attr_UniqueFireIdentifier ?? p.poly_IRWINID, name: p.poly_IncidentName, acres: p.poly_GISAcres ?? null, percentContained: p.attr_PercentContained ?? null, updatedAt: p.attr_ModifiedOnDateTime_dt ? new Date(p.attr_ModifiedOnDateTime_dt).toISOString() : null, rings };
    }).filter((p) => p.rings.length);
    return { value: items };
  });
}

async function calfire() {
  return sourced("calfire", "CAL FIRE active incidents", "https://www.fire.ca.gov/incidents", async () => {
    const { data } = await fetchJSON(CALFIRE_URL);
    return { value: (Array.isArray(data) ? data : []).map((i) => ({ id: `calfire-${i.UniqueId}`, name: i.Name, source: "CAL FIRE", type: i.Type === "Wildfire" ? "WF" : i.Type ?? null, acres: i.AcresBurned ?? null, percentContained: i.PercentContained ?? null, discoveredAt: i.Started ? new Date(i.Started).toISOString() : null, updatedAt: i.Updated ? new Date(i.Updated).toISOString() : null, latitude: i.Latitude, longitude: i.Longitude, county: i.County ?? null, url: i.Url ?? null, inciwebUrl: null })) };
  });
}

async function inciweb() {
  return sourced("inciweb", "InciWeb incident feed (links)", "https://inciweb.wildfire.gov/", async () => {
    const { text } = await fetchText(INCIWEB_RSS, { accept: "application/rss+xml, text/xml" });
    const items = [...text.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((m) => {
      const b = m[1];
      const get = (tag) => /<\s*TAG\s*>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/\s*TAG\s*>/.exec(b.replace(/TAG/g, tag)) ?? null;
      const title = /<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>/.exec(b)?.[1]?.trim() ?? "";
      const link = /<link>([\s\S]*?)<\/link>/.exec(b)?.[1]?.trim() ?? null;
      const desc = /<description>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/description>/.exec(b)?.[1] ?? "";
      const lat = /Latitude:?\s*(-?\d+\.\d+)/i.exec(desc)?.[1];
      const lon = /Longitude:?\s*(-?\d+\.\d+)/i.exec(desc)?.[1];
      void get;
      return { title, link, latitude: lat ? Number(lat) : null, longitude: lon ? Number(lon) : null };
    });
    return { value: items };
  });
}

async function firms() {
  const key = env("FIRMS_MAP_KEY");
  const bbox = `${PARK_BBOX.west},${PARK_BBOX.south},${PARK_BBOX.east},${PARK_BBOX.north}`;
  const result = await sourced("firms", "NASA FIRMS VIIRS active-fire hotspots (keyed)", `https://firms.modaps.eosdis.nasa.gov/usfs/map/#d:24hrs;@${VALLEY.longitude},${VALLEY.latitude},10.0z`, async () => {
    if (!key) throw Object.assign(new Error("FIRMS_MAP_KEY not configured"), { status: 0 });
    const sources = ["VIIRS_NOAA20_NRT", "VIIRS_SNPP_NRT", "VIIRS_NOAA21_NRT"];
    const items = [];
    for (const source of sources) {
      const { text } = await fetchText(`https://firms.modaps.eosdis.nasa.gov/api/area/csv/${key}/${source}/${bbox}/2`, { accept: "text/csv" });
      const [header, ...rows] = text.trim().split(/\r?\n/);
      if (!header || !rows.length) continue;
      const cols = header.split(",");
      for (const row of rows) {
        const r = Object.fromEntries(row.split(",").map((v, i) => [cols[i], v]));
        const time = `${r.acq_date}T${String(r.acq_time).padStart(4, "0").replace(/(\d{2})(\d{2})/, "$1:$2")}:00Z`;
        items.push({ latitude: Number(r.latitude), longitude: Number(r.longitude), acquiredAt: time, satellite: r.satellite === "N" ? "NOAA-20" : r.satellite === "1" ? "NOAA-21" : "Suomi NPP", confidence: r.confidence ?? null, frpMw: r.frp ? Number(r.frp) : null, daytime: r.daynight === "D", incidentId: null, source });
      }
    }
    const cutoff = Date.now() - HOTSPOT_WINDOW_HOURS * 3_600_000;
    const recent = items.filter((h) => Date.parse(h.acquiredAt) >= cutoff);
    return { value: { items: recent, sources }, sourceTime: recent.map((h) => h.acquiredAt).sort().at(-1) };
  });
  return result;
}

async function airnow() {
  const key = env("AIRNOW_API_KEY");
  return sourced("airnow", "AirNow API current observations by lat/long (documented, keyed)", "https://www.airnow.gov/?city=Yosemite%20National%20Park&state=CA&country=USA", async () => {
    if (!key) throw Object.assign(new Error("AIRNOW_API_KEY not configured"), { status: 0 });
    const url = `https://www.airnowapi.org/aq/observation/latLong/current/?format=application/json&latitude=${VALLEY.latitude}&longitude=${VALLEY.longitude}&distance=50&API_KEY=${key}`;
    const { data } = await fetchJSON(url);
    const readings = (Array.isArray(data) ? data : []).map((r) => ({ site: r.ReportingArea, parameter: r.ParameterName, aqi: r.AQI, category: r.Category?.Name ?? null, value: null, units: null, observedAt: r.DateObserved && r.HourObserved != null ? new Date(`${r.DateObserved.trim()}T${String(r.HourObserved).padStart(2, "0")}:00:00${offsetFor(r.LocalTimeZone)}`).toISOString() : null, agency: null, method: "AirNow API current NowCast observation (closest reading by pollutant within 50 miles)", latitude: r.Latitude ?? null, longitude: r.Longitude ?? null }));
    return { value: readings, sourceTime: readings[0]?.observedAt };
  });
}

function offsetFor(tz) { return tz === "PDT" ? "-07:00" : tz === "PST" ? "-08:00" : "Z"; }

function updateTracking(incidents, hotspots, perimeters) {
  const tracking = readJSON("tracking.json", { since: nowISO(), incidents: [], previousPerimeters: [] });
  const t = nowISO();
  for (const inc of incidents) {
    let entry = tracking.incidents.find((e) => e.id === inc.id);
    if (!entry) { entry = { id: inc.id, name: inc.name, points: [] }; tracking.incidents.push(entry); }
    const perimeter = perimeters.find((p) => p.id === inc.id);
    const detections12h = hotspots.filter((h) => h.incidentId === inc.id && Date.parse(h.acquiredAt) >= Date.now() - 12 * 3_600_000).length;
    const last = entry.points.at(-1);
    const point = { t, acres: inc.acres, perimeterAcres: perimeter?.acres ?? null, percentContained: inc.percentContained, detections12h };
    if (!last || last.acres !== point.acres || last.percentContained !== point.percentContained || last.detections12h !== point.detections12h || Date.parse(t) - Date.parse(last.t) > 6 * 3_600_000) entry.points.push(point);
    if (entry.points.length > 400) entry.points = entry.points.slice(-400);
  }
  tracking.incidents = tracking.incidents.filter((e) => incidents.some((i) => i.id === e.id) || Date.parse(e.points.at(-1)?.t ?? 0) > Date.now() - 14 * 86_400_000);
  writeJSON("tracking.json", tracking);
  return tracking;
}

export async function buildSmoke() {
  const statuses = [];
  const monitorsResult = await sourced("nps-air", "NPS Yosemite air monitors (5 sites)", "https://www.nps.gov/subjects/air/current-data.htm?site=yose", async () => {
    const { data } = await fetchJSON(NPS_MONITORS);
    const readings = [];
    for (const site of data.sites ?? data ?? []) {
      for (const p of site.parameters ?? []) readings.push({ site: site.name ?? site.siteName ?? "NPS monitor", parameter: p.name ?? p.parameter, aqi: p.aqi ?? null, category: p.category ?? null, value: p.value ?? null, units: p.units ?? null, observedAt: p.time ?? site.time ?? null, agency: "National Park Service", method: "NPS air resources current data", latitude: site.latitude ?? null, longitude: site.longitude ?? null });
    }
    return { value: { readings, dataDate: data.date ?? null } };
  });
  statuses.push(monitorsResult.status);
  const airnowResult = await airnow();
  statuses.push(airnowResult.status);
  const plumesResult = await hmsPlumes();
  statuses.push(plumesResult.status);
  const incidentsResult = await nifcIncidents();
  statuses.push(incidentsResult.status);
  const calfireResult = await calfire();
  statuses.push(calfireResult.status);
  const inciwebResult = await inciweb();
  statuses.push(inciwebResult.status);
  const perimetersResult = await nifcPerimeters();
  statuses.push(perimetersResult.status);
  const firmsResult = await firms();
  statuses.push(firmsResult.status);

  // Merge incidents by proximity (NIFC canonical; CAL FIRE adds url/acres when NIFC lacks them).
  const incidents = [...(incidentsResult.value ?? [])];
  for (const c of calfireResult.value ?? []) {
    const match = incidents.find((i) => haversineMiles(i.latitude, i.longitude, c.latitude, c.longitude) < 3 && i.name.toLowerCase().replace(/ fire$/, "") === c.name.toLowerCase().replace(/ fire$/, ""));
    if (match) { match.url = match.url ?? c.url; match.acres = match.acres ?? c.acres; match.percentContained = match.percentContained ?? c.percentContained; }
    else incidents.push(c);
  }
  for (const w of inciwebResult.value ?? []) {
    if (w.latitude == null) continue;
    const match = incidents.find((i) => haversineMiles(i.latitude, i.longitude, w.latitude, w.longitude) < 5);
    if (match && !match.inciwebUrl) match.inciwebUrl = w.link;
  }
  const near = incidents.map((i) => ({ ...i, distanceMiles: Math.round(haversineMiles(VALLEY.latitude, VALLEY.longitude, i.latitude, i.longitude)), bearing: bearingName(VALLEY.latitude, VALLEY.longitude, i.latitude, i.longitude) })).filter((i) => i.distanceMiles <= INCIDENT_RADIUS_MILES).sort((a, b) => a.distanceMiles - b.distanceMiles);

  const hotspots = firmsResult.value?.items ?? [];
  const perimeters = perimetersResult.value ?? [];
  for (const h of hotspots) {
    const inside = perimeters.find((p) => p.rings.some((ring) => pointInRing(h.longitude, h.latitude, ring)));
    const nearest = inside ?? near.find((i) => haversineMiles(i.latitude, i.longitude, h.latitude, h.longitude) < 5);
    h.incidentId = nearest?.id ?? null;
  }
  for (const i of near) {
    const mine = hotspots.filter((h) => h.incidentId === i.id);
    i.hotspotCount = mine.length;
    i.latestHotspotAt = mine.map((h) => h.acquiredAt).sort().at(-1) ?? null;
    i.perimeterAcres = perimeters.find((p) => p.id === i.id)?.acres ?? null;
  }
  const tracking = updateTracking(near, hotspots, perimeters);

  const polygons = (plumesResult.value?.polygons ?? []).filter((p) => bboxIntersects(p.ring));
  const rank = { Light: 1, Medium: 2, Heavy: 3 };
  const points = FORECAST_POINTS.map((pt) => {
    let density = null, observedAt = null;
    for (const poly of polygons) {
      if (pointInRing(pt.longitude, pt.latitude, poly.ring) && !(poly.holes ?? []).some((h) => pointInRing(pt.longitude, pt.latitude, h)) && (!density || rank[poly.density] > rank[density])) { density = poly.density; observedAt = poly.end ?? poly.start; }
    }
    return { pointKey: pt.key, label: pt.label, density, observedAt };
  });

  return {
    kind: "smoke", version: 1, fetchedAt: nowISO(),
    monitors: { state: monitorsResult.status.state, checkedAt: monitorsResult.status.checkedAt, dataDate: monitorsResult.value?.dataDate ?? null, readings: monitorsResult.value?.readings ?? [], url: NPS_MONITORS, ...(monitorsResult.status.detail ? { detail: monitorsResult.status.detail } : {}) },
    airnow: { state: airnowResult.status.state, checkedAt: airnowResult.status.checkedAt, readings: airnowResult.value ?? [], forecasts: [], url: "https://docs.airnowapi.org/ObservationsByZipCodeLatLon/docs", ...(airnowResult.status.detail ? { detail: airnowResult.status.detail } : {}) },
    plumes: { state: plumesResult.status.state, checkedAt: plumesResult.status.checkedAt, analysisDate: plumesResult.value?.date ?? null, url: plumesResult.value?.url ?? null, points, polygonsChecked: plumesResult.value?.polygons?.length ?? 0, polygons, ...(plumesResult.status.detail ? { detail: plumesResult.status.detail } : {}) },
    hotspots: { state: firmsResult.status.state, checkedAt: firmsResult.status.checkedAt, windowHours: HOTSPOT_WINDOW_HOURS, bbox: [PARK_BBOX.west, PARK_BBOX.south, PARK_BBOX.east, PARK_BBOX.north], items: hotspots, latestAt: hotspots.map((h) => h.acquiredAt).sort().at(-1) ?? null, unattributed: hotspots.filter((h) => !h.incidentId).length, sources: firmsResult.value?.sources ?? [], url: firmsResult.status.url, ...(firmsResult.status.detail ? { detail: firmsResult.status.detail } : {}) },
    incidents: { state: incidentsResult.status.state, checkedAt: incidentsResult.status.checkedAt, radiusMiles: INCIDENT_RADIUS_MILES, items: near, sources: { nifc: incidentsResult.status.state, calfire: calfireResult.status.state, inciweb: inciwebResult.status.state }, ...(incidentsResult.status.detail ? { detail: incidentsResult.status.detail } : {}) },
    perimeters: { state: perimetersResult.status.state, checkedAt: perimetersResult.status.checkedAt, items: perimeters, url: perimetersResult.status.url, ...(perimetersResult.status.detail ? { detail: perimetersResult.status.detail } : {}) },
    tracking,
    statuses,
  };
}
