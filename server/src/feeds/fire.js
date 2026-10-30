import { fetchJSON, fetchText, sourced, nowISO } from "../lib/http.js";
import { npsAlerts, stripHtml } from "./nps.js";
import { VALLEY } from "../lib/geo.js";

const FWF_LIST = "https://api.weather.gov/products/types/FWF/locations/HNX";
const RESTRICTIONS_URL = "https://www.nps.gov/yose/planyourvisit/firerestrictions.htm";
const FIRE_TERMS = /\b(fire|smoke|smoky|red flag|air quality|wildfire|burn)\b/i;

/** Extracts the Central Sierra (CAZ592) zone section from an FWF product text. */
export function parseFWF(text, zone = "CAZ592") {
  const zoneIndex = text.indexOf(zone);
  const discussionMatch = /\.DISCUSSION\.\.\.([\s\S]*?)(?:\n\s*\n(?=[A-Z]{3}\d{3}|\$\$|\.|\w)|$)/.exec(text);
  const discussion = discussionMatch ? discussionMatch[1].replace(/\s+/g, " ").trim() : null;
  let zoneName = null;
  let periods = [];
  if (zoneIndex >= 0) {
    const section = text.slice(zoneIndex, text.indexOf("$$", zoneIndex) > 0 ? text.indexOf("$$", zoneIndex) : undefined);
    const nameMatch = /\n([A-Za-z][A-Za-z /&-]+?)-\d{6}-/.exec(section) || /\n\s*([A-Z][A-Za-z ]+)\s*\n/.exec(section);
    zoneName = nameMatch ? nameMatch[1].trim() : null;
    const blocks = section.split(/\n\.(?=[A-Z][A-Za-z ]+\.\.\.)/).slice(1);
    for (const block of blocks) {
      const header = /^([A-Za-z ]+)\.\.\./.exec(block);
      if (!header) continue;
      const field = (label) => {
        const m = new RegExp(`(?:${label})\\.{2,}\\s*([^\\n]+(?:\\n\\s{6,}[^\\n]+)*)`, "i").exec(block);
        return m ? m[1].replace(/\s+/g, " ").trim() : null;
      };
      periods.push({ name: header[1].trim(), skyWeather: field("Sky/weather"), thunder: field("Chance of tstms|Thunder"), maxTemperature: field("Max temperature"), minTemperature: field("Min temperature"), minHumidity: field("Min humidity"), maxHumidity: field("Max humidity"), wettingRain: field("Chance of wetting rain|Wetting rain"), windsSlopes: field("Wind \\(20 ft\\)|Slope/valley winds|Winds? \\(slopes?\\)"), windsRidges: field("Ridge winds|Winds? \\(ridges?\\)") });
    }
    periods = periods.slice(0, 6);
  }
  return { zone, zoneName, discussion, periods };
}

/** Transparent planning heuristic. Inputs and reasons are returned with the result. */
export function assess({ metrics, restrictions, noticeMatches, alertMatches }) {
  const reasons = [];
  let priority = 1;
  let label = "No dry-pattern signals in returned inputs";
  if (alertMatches.length) { priority = Math.max(priority, 5); reasons.push(`NWS alert mentions fire terms: ${alertMatches.join(", ")}`); }
  if (noticeMatches.length) { priority = Math.max(priority, 4); reasons.push(`NPS notice mentions fire terms: ${noticeMatches.join(", ")}`); }
  if (restrictions.state === "ready" && restrictions.inEffect) { priority = Math.max(priority, 4); reasons.push("NPS lists seasonal fire restrictions in effect"); }
  if (metrics.state === "ready") {
    if (metrics.minHumidityPct != null && metrics.minHumidityPct <= 30) { priority = Math.max(priority, 3); reasons.push(`Minimum humidity ${metrics.minHumidityPct}% ≤ 30%`); }
    if (metrics.maxPrecipChancePct != null && metrics.maxPrecipChancePct <= 20 && metrics.minHumidityPct != null && metrics.minHumidityPct <= 30) reasons.push(`Maximum precipitation chance ${metrics.maxPrecipChancePct}% ≤ 20%`);
    if (metrics.maxWindMph != null && metrics.maxWindMph >= 25) { priority = Math.max(priority, 3); reasons.push(`Maximum wind ${metrics.maxWindMph} mph ≥ 25 mph`); }
    if (metrics.thunderHours > 0) { priority = Math.max(priority, 3); reasons.push(`${metrics.thunderHours} forecast hours mention thunderstorms`); }
  } else {
    reasons.push("Hourly forecast unavailable; weather inputs missing");
  }
  if (priority >= 5) label = "Official fire-related alert in effect";
  else if (priority === 4) label = "Official fire notice or restriction in effect";
  else if (priority === 3) label = "Dry pattern — monitor changes";
  else if (metrics.state !== "ready") label = "Inputs incomplete — no assessment";
  const inputs = {
    "Official fire/smoke signals": alertMatches.length || noticeMatches.length ? `${alertMatches.length + noticeMatches.length} matched` : "none matched in returned notices",
    "NPS restrictions": restrictions.state === "ready" ? (restrictions.inEffect ? "in effect" : "none listed") : "unknown",
    "Min humidity (24 h)": metrics.minHumidityPct != null ? `${metrics.minHumidityPct}%` : "n/a",
    "Max wind (24 h)": metrics.maxWindMph != null ? `${metrics.maxWindMph} mph` : "n/a",
    "Max precip chance (24 h)": metrics.maxPrecipChancePct != null ? `${metrics.maxPrecipChancePct}%` : "n/a",
    "Thunderstorm hours (24 h)": metrics.thunderHours != null ? String(metrics.thunderHours) : "n/a",
  };
  return { priority, label, reasons, inputs, heuristicNote: "Application planning heuristic from returned inputs. Not an official fire-danger rating, evacuation signal, or proof that no fire is burning." };
}

export async function buildFire() {
  const statuses = [];
  const coords = `${VALLEY.latitude},${VALLEY.longitude}`;
  const hourlyResult = await sourced("nws-hourly", "NWS hourly forecast (Valley point)", `https://api.weather.gov/points/${coords}`, async () => {
    const { data: point } = await fetchJSON(`https://api.weather.gov/points/${coords}`);
    const { data } = await fetchJSON(point.properties.forecastHourly);
    return { value: data.properties, sourceTime: data.properties.updateTime };
  });
  statuses.push(hourlyResult.status);
  const metrics = { state: hourlyResult.ok ? "ready" : "unavailable", checkedAt: hourlyResult.status.checkedAt };
  if (hourlyResult.value) {
    const periods = (hourlyResult.value.periods ?? []).slice(0, 24);
    const rh = periods.map((p) => p.relativeHumidity?.value).filter((v) => v != null);
    const temps = periods.map((p) => p.temperature).filter((v) => v != null);
    const winds = periods.map((p) => Number.parseInt(p.windSpeed, 10)).filter((v) => !Number.isNaN(v));
    const precip = periods.map((p) => p.probabilityOfPrecipitation?.value).filter((v) => v != null);
    Object.assign(metrics, { hoursCovered: periods.length, minHumidityPct: rh.length ? Math.min(...rh) : null, maxTemperatureF: temps.length ? Math.max(...temps) : null, maxWindMph: winds.length ? Math.max(...winds) : null, maxPrecipChancePct: precip.length ? Math.max(...precip) : null, thunderHours: periods.filter((p) => /thunder|t-storm/i.test(p.shortForecast ?? "")).length, windowStart: periods[0]?.startTime ?? null, windowEnd: periods.at(-1)?.endTime ?? null });
  } else {
    metrics.detail = hourlyResult.status.detail;
  }

  const alertsUrl = `https://api.weather.gov/alerts/active?point=${coords}`;
  const alertsResult = await sourced("nws-alerts", "NWS alerts (Valley point)", alertsUrl, async () => ({ value: (await fetchJSON(alertsUrl)).data.features ?? [] }));
  statuses.push(alertsResult.status);
  const alertItems = (alertsResult.value ?? []).map((f) => ({ id: f.properties.id ?? f.id, event: f.properties.event, headline: f.properties.headline ?? null, severity: f.properties.severity ?? null, urgency: f.properties.urgency ?? null, onset: f.properties.onset ?? null, ends: f.properties.ends ?? null, expires: f.properties.expires ?? null, description: f.properties.description ?? null, instruction: f.properties.instruction ?? null, areaDesc: f.properties.areaDesc ?? null, url: f.id ?? null }));
  const alertMatches = alertItems.filter((a) => FIRE_TERMS.test(`${a.event} ${a.headline ?? ""}`)).map((a) => a.event);

  const fwfResult = await sourced("nws-fwf", "NWS Hanford fire weather forecast (CAZ592)", FWF_LIST, async () => {
    const { data: list } = await fetchJSON(FWF_LIST);
    const latest = (list["@graph"] ?? [])[0];
    if (!latest) throw new Error("no FWF product listed");
    const { data: product } = await fetchJSON(latest["@id"]);
    return { value: { ...parseFWF(product.productText ?? ""), issuedAt: product.issuanceTime, url: latest["@id"] }, sourceTime: product.issuanceTime };
  });
  if (fwfResult.ok) fwfResult.status.url = fwfResult.value.url;
  statuses.push(fwfResult.status);
  const fwf = { state: fwfResult.ok ? "ready" : "unavailable", checkedAt: fwfResult.status.checkedAt, issuedAt: fwfResult.value?.issuedAt ?? null, url: fwfResult.value?.url ?? FWF_LIST, discussion: fwfResult.value?.discussion ?? null, zone: "CAZ592", zoneName: fwfResult.value?.zoneName ?? "Central Sierra", periods: fwfResult.value?.periods ?? [] };
  if (!fwfResult.ok) fwf.detail = fwfResult.status.detail;

  const noticesResult = await npsAlerts();
  statuses.push(noticesResult.status);
  const noticeItems = noticesResult.value ?? [];
  const noticeMatches = noticeItems.filter((n) => FIRE_TERMS.test(`${n.title} ${n.description}`)).map((n) => n.title);

  const restrictionsResult = await sourced("nps-restrictions", "NPS fire restrictions page", RESTRICTIONS_URL, async () => {
    const { text: html, lastModified } = await fetchText(RESTRICTIONS_URL, { accept: "text/html" });
    const plain = stripHtml(html);
    const updated = /Last updated:?\s*([A-Z][a-z]+ \d{1,2}, \d{4})/i.exec(plain);
    const pageUpdated = updated ? new Date(`${updated[1]} UTC`).toISOString() : lastModified ? new Date(lastModified).toISOString() : null;
    const sentence = /([^.]*\b(?:no (?:seasonal )?fire restrictions|fire restrictions (?:are|remain) in (?:effect|place)|restrictions are in effect)[^.]*\.)/i.exec(plain);
    if (!sentence) return { value: { text: null, pageUpdated, inEffect: null }, state: "unknown", detail: "Section text did not match known phrasing", sourceTime: pageUpdated };
    const text = sentence[1].replace(/\s+/g, " ").trim();
    return { value: { text, pageUpdated, inEffect: !/no (?:seasonal )?fire restrictions/i.test(text) }, sourceTime: pageUpdated };
  });
  statuses.push(restrictionsResult.status);
  const restrictions = { state: restrictionsResult.status.state, checkedAt: restrictionsResult.status.checkedAt, text: restrictionsResult.value?.text ?? null, pageUpdated: restrictionsResult.value?.pageUpdated ?? null, url: RESTRICTIONS_URL, inEffect: restrictionsResult.value?.inEffect ?? null };
  if (restrictionsResult.status.detail) restrictions.detail = restrictionsResult.status.detail;

  const assessment = assess({ metrics, restrictions, noticeMatches, alertMatches });
  return {
    kind: "fire", version: 1, fetchedAt: nowISO(), assessment, metrics, restrictions, fwf,
    notices: { state: noticesResult.status.state, checkedAt: noticesResult.status.checkedAt, items: noticeItems, fireMatches: noticeMatches },
    alerts: { state: alertsResult.ok ? "ready" : "unavailable", checkedAt: alertsResult.status.checkedAt, items: alertItems, fireMatches: alertMatches },
    statuses,
  };
}
