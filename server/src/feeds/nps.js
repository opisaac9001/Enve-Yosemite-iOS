import { fetchJSON, sourced } from "../lib/http.js";
import { env } from "../lib/env.js";

const NPS_API = "https://developer.nps.gov/api/v1";
export const NPS_DOCS = "https://www.nps.gov/subjects/developer/api-documentation.htm";

function keyed() {
  const key = env("NPS_API_KEY");
  return key ? { "X-Api-Key": key } : null;
}

async function npsGet(path, params) {
  const headers = keyed();
  if (!headers) throw Object.assign(new Error("NPS_API_KEY not configured"), { status: 0 });
  const url = new URL(`${NPS_API}/${path}`);
  url.searchParams.set("parkCode", "yose");
  for (const [k, v] of Object.entries(params ?? {})) url.searchParams.set(k, v);
  const { data } = await fetchJSON(url.toString(), { headers });
  return data;
}

/** NPS alerts as notice items. */
export async function npsAlerts() {
  const url = `${NPS_DOCS}#/alerts/getAlerts`;
  const result = await sourced("nps-notices", "NPS Yosemite alerts (NPS Developer API)", url, async () => {
    const data = await npsGet("alerts", { limit: "50" });
    return { value: (data.data ?? []).map((a) => ({
      id: a.id, title: a.title, description: a.description ?? "", category: a.category ?? null, url: a.url || null,
      lastModified: a.lastIndexedDate ? new Date(a.lastIndexedDate).toISOString() : null, startDate: null, endDate: null, siteCode: a.parkCode ?? "yose",
    })) };
  });
  if (!keyed()) result.status.detail = "NPS_API_KEY not configured";
  return result;
}

export async function npsRoadEvents() {
  const url = `${NPS_DOCS}#/roadevents/getRoadEvents`;
  return sourced("nps-roadevents", "NPS Developer API road events", url, async () => {
    const data = await npsGet("roadevents", { limit: "50" });
    const items = (data.data ?? []).map((e, i) => ({
      id: `roadevent:${e.id ?? i}`, kind: "roadevent", title: e.title ?? e.name ?? "Road event", statusText: e.status ?? null, status: null,
      text: e.description ?? "", area: "NPS road events", subjects: [], url: e.url || null, sourceDate: e.lastUpdated ?? null, start: e.startDate ?? null, end: e.endDate ?? null,
    }));
    return { value: { items, feedUpdated: data.data?.[0]?.lastUpdated ?? null } };
  });
}

export async function npsEvents(start, end) {
  const url = `${NPS_DOCS}#/events/getEvents`;
  return sourced("nps-events", "NPS calendar (NPS Developer API)", url, async () => {
    const data = await npsGet("events", { dateStart: start, dateEnd: end, pageSize: "200" });
    const items = (data.data ?? []).map((e) => ({
      id: e.id, eventId: e.eventid ?? null, title: e.title, types: e.types ?? [], description: stripHtml(e.description ?? ""), location: e.location ?? null,
      dates: e.dates ?? [], cancelledDates: [], times: (e.times ?? []).map((t) => ({ start: t.timestart ?? null, end: t.timeend ?? null, startMinutes: minutes(t.timestart), sunriseStart: !!t.sunrisestart, sunsetEnd: !!t.sunsetend })),
      allDay: e.isallday === "true" || e.isallday === true, recurring: e.isrecurring === "true" || e.isrecurring === true, recurrenceRule: e.recurrencerule || null,
      excludedDates: [], seriesStart: e.recurrencedatestart || null, seriesEnd: e.recurrencedateend || null, isFree: e.isfree === "true" || e.isfree === true, feeInfo: stripHtml(e.feeinfo ?? "") || null,
      registrationRequired: e.isregresrequired === "true" || e.isregresrequired === true, registrationInfo: stripHtml(e.regresinfo ?? "") || null, registrationUrl: e.regresurl || null,
      infoUrl: e.infourl || null, timeInfo: stripHtml(e.timeinfo ?? "") || null, created: e.datecreated ?? null, updated: e.dateupdated ?? null,
      url: `https://www.nps.gov/planyourvisit/event-details.htm?id=${e.id}`,
    }));
    return { value: { items, total: Number(data.total ?? items.length) } };
  });
}

export async function npsVisitorCenters() {
  const url = `${NPS_DOCS}#/visitorcenters/getVisitorCenters`;
  return sourced("nps-visitor-centers", "NPS visitor-center hours (NPS Developer API)", url, async () => {
    const data = await npsGet("visitorcenters", { limit: "20" });
    const items = (data.data ?? []).map((v) => ({
      id: v.id, name: v.name, url: v.url || null, lastIndexed: v.lastIndexedDate || null,
      hours: (v.operatingHours ?? []).map((h) => ({ name: h.name, description: h.description ?? null, standard: h.standardHours ?? {}, exceptions: (h.exceptions ?? []).map((x) => ({ name: x.name, startDate: x.startDate ?? null, endDate: x.endDate ?? null, hours: x.exceptionHours ?? {} })) })),
    }));
    return { value: items };
  });
}

function minutes(hhmm) {
  if (!hhmm) return null;
  const m = /^(\d{1,2}):(\d{2})\s*(AM|PM)?$/i.exec(hhmm.trim());
  if (!m) return null;
  let h = Number(m[1]);
  if (m[3]) { if (m[3].toUpperCase() === "PM" && h < 12) h += 12; if (m[3].toUpperCase() === "AM" && h === 12) h = 0; }
  return h * 60 + Number(m[2]);
}

export function stripHtml(s) {
  return s.replace(/<br\s*\/?>/gi, "\n").replace(/<\/p>/gi, "\n").replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&#39;|&rsquo;/g, "’").replace(/&quot;/g, '"').replace(/\n{3,}/g, "\n\n").trim();
}
