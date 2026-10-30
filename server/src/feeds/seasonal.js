import { fetchJSON, sourced, nowISO } from "../lib/http.js";
import { env } from "../lib/env.js";
import { npsAlerts } from "./nps.js";

const USGS_SITE = "11266500";
const USGS_URL = `https://waterservices.usgs.gov/nwis/iv/?format=json&sites=${USGS_SITE}&parameterCd=00060,00065&siteStatus=all`;
const CHAIN_ROUTES = ["SR-41", "SR-120", "SR-140"];
const CHAIN_DISTRICTS = ["6", "9", "10"];

/** Normalises a Caltrans CWWP2 chain-control record; the feed's field names vary by district export. */
export function normaliseChainRecord(record, district) {
  const r = record.cc ?? record;
  const route = r.route ?? r.location?.route ?? r.Route ?? "";
  const routeName = /^(?:SR|CA|US|I)?-?\s*(\d+)/i.exec(String(route))?.[1];
  const key = routeName ? `SR-${routeName}` : String(route);
  const statusText = r.chainControlStatus ?? r.status ?? r.ccStatus ?? r.chainControl ?? "";
  const requirement = /R-?3/i.test(statusText) ? "R3" : /R-?2/i.test(statusText) ? "R2" : /R-?1/i.test(statusText) ? "R1" : /no (?:chain )?control|none/i.test(statusText) ? null : statusText ? "unknown" : null;
  return {
    route: key, district, requirement,
    location: r.locationDescription ?? r.location?.description ?? r.description ?? r.nearbyPlace ?? null,
    text: statusText || null,
    recordedAt: r.recordTimestamp?.recordDate && r.recordTimestamp?.recordTime ? `${r.recordTimestamp.recordDate}T${r.recordTimestamp.recordTime}` : r.recordTimestamp ?? r.updated ?? null,
  };
}

async function chainDistrict(district, template) {
  const url = template.replaceAll("{district}", district);
  const checkedAt = nowISO();
  try {
    const { data } = await fetchJSON(url);
    const records = Array.isArray(data) ? data : data.data ?? data.chainControls ?? data.cc ?? [];
    const signs = records.map((r) => normaliseChainRecord(r, district)).filter((s) => CHAIN_ROUTES.includes(s.route));
    const latest = signs.map((s) => s.recordedAt).filter(Boolean).sort().at(-1) ?? null;
    return { id: district, state: "ready", checkedAt, signsChecked: signs.length, feedRecordedAt: latest, active: signs.filter((s) => s.requirement && s.requirement !== "unknown" ? true : false) };
  } catch (error) {
    return { id: district, state: "unavailable", checkedAt, detail: error.status ? `HTTP ${error.status}` : error.message, active: [], signsChecked: 0 };
  }
}

export async function buildSeasonal() {
  const statuses = [];
  const notices = await npsAlerts();
  statuses.push(notices.status);

  const river = await sourced("usgs-river", "USGS Merced River at Pohono Bridge", `https://waterdata.usgs.gov/monitoring-location/${USGS_SITE}/`, async () => {
    const { data } = await fetchJSON(USGS_URL);
    const series = data.value?.timeSeries ?? [];
    const pick = (code) => {
      const s = series.find((t) => t.variable?.variableCode?.[0]?.value === code);
      const v = s?.values?.[0]?.value?.at(-1);
      return v ? { value: Number(v.value), time: new Date(v.dateTime).toISOString(), provisional: (v.qualifiers ?? []).includes("P") } : null;
    };
    const discharge = pick("00060");
    const stage = pick("00065");
    if (!discharge && !stage) throw new Error("no readings returned");
    return { value: { siteName: series[0]?.sourceInfo?.siteName ?? null, discharge, stage }, sourceTime: discharge?.time ?? stage?.time };
  });
  statuses.push(river.status);

  const template = env("CALTRANS_CC_URL_TEMPLATE", "https://cwwp2.dot.ca.gov/data/d{district}/cwwp2_d{district}_cc.json");
  const districts = await Promise.all(CHAIN_DISTRICTS.map((d) => chainDistrict(d, template)));
  const chainsState = districts.every((d) => d.state === "ready") ? "ready" : districts.some((d) => d.state === "ready") ? "unknown" : "unavailable";
  const chainsCheckedAt = nowISO();
  statuses.push({ key: "caltrans-chains", label: "Caltrans chain controls (D6/D9/D10, SR-41/120/140)", state: chainsState, checkedAt: chainsCheckedAt, url: "https://cwwp2.dot.ca.gov/", detail: chainsState === "ready" ? undefined : districts.filter((d) => d.state !== "ready").map((d) => `D${d.id}: ${d.detail}`).join("; ") });

  return {
    kind: "seasonal", version: 1, fetchedAt: nowISO(),
    notices: { state: notices.status.state, checkedAt: notices.status.checkedAt, items: notices.value ?? [] },
    river: { state: river.status.state, checkedAt: river.status.checkedAt, siteId: USGS_SITE, siteName: river.value?.siteName ?? null, dischargeCfs: river.value?.discharge?.value ?? null, dischargeTime: river.value?.discharge?.time ?? null, stageFt: river.value?.stage?.value ?? null, stageTime: river.value?.stage?.time ?? null, provisional: river.value?.discharge?.provisional ?? river.value?.stage?.provisional ?? null, url: `https://waterdata.usgs.gov/monitoring-location/${USGS_SITE}/`, ...(river.status.detail ? { detail: river.status.detail } : {}) },
    chains: { state: chainsState, checkedAt: chainsCheckedAt, districts: districts.map(({ active, ...d }) => d), activeControls: districts.flatMap((d) => d.active), signsChecked: districts.reduce((a, d) => a + (d.signsChecked ?? 0), 0), routes: CHAIN_ROUTES },
    statuses,
  };
}
