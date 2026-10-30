import { fetchJSON, sourced, nowISO } from "../lib/http.js";
import { pointByKey } from "../lib/points.js";

const NWS = "https://api.weather.gov";

function toF(value, unit) {
  if (value == null) return null;
  return unit && /degC/i.test(unit) ? Math.round((value * 9) / 5 + 32) : Math.round(value);
}

function period(p) {
  return {
    start: p.startTime,
    end: p.endTime,
    isDaytime: !!p.isDaytime,
    temperatureF: toF(p.temperature, p.temperatureUnit === "C" ? "degC" : null),
    dewPointF: p.dewpoint?.value != null ? toF(p.dewpoint.value, p.dewpoint.unitCode) : null,
    humidityPct: p.relativeHumidity?.value ?? null,
    windMph: p.windSpeed ? Number.parseInt(p.windSpeed, 10) || null : null,
    windDirection: p.windDirection ?? null,
    precipChancePct: p.probabilityOfPrecipitation?.value ?? null,
    shortForecast: p.shortForecast ?? null,
  };
}

export async function buildWeather(pointKey) {
  const point = pointByKey(pointKey);
  if (!point) throw Object.assign(new Error("unknown point"), { status: 400 });
  const statuses = [];
  const sources = {};
  const coords = `${point.latitude},${point.longitude}`;

  const pointsUrl = `${NWS}/points/${coords}`;
  sources.points = pointsUrl;
  const pointsResult = await sourced("nws-point", "NWS point", pointsUrl, async () => ({ value: (await fetchJSON(pointsUrl)).data.properties }));
  statuses.push(pointsResult.status);
  const props = pointsResult.value;

  let hourly = [];
  let forecastUpdatedAt = null;
  if (props?.forecastHourly) {
    sources.forecastHourly = props.forecastHourly;
    const r = await sourced("nws-hourly", "NWS hourly forecast", props.forecastHourly, async () => {
      const { data } = await fetchJSON(props.forecastHourly);
      return { value: data.properties, sourceTime: data.properties.updateTime ?? data.properties.generatedAt };
    });
    statuses.push(r.status);
    if (r.value) {
      hourly = (r.value.periods ?? []).slice(0, 48).map(period);
      forecastUpdatedAt = r.value.updateTime ?? r.value.generatedAt ?? null;
    }
  }

  let observation = null;
  if (props?.observationStations) {
    const stationsResult = await sourced("nws-stations", "NWS observation stations", props.observationStations, async () => ({ value: (await fetchJSON(props.observationStations)).data.features ?? [] }));
    const station = stationsResult.value?.[0];
    if (station) {
      const id = station.properties.stationIdentifier;
      const url = `${NWS}/stations/${id}/observations/latest`;
      sources.station = url;
      const r = await sourced("nws-observation", `Observation · ${station.properties.name} ${id}`, url, async () => {
        const { data } = await fetchJSON(url);
        return { value: data.properties, sourceTime: data.properties.timestamp };
      });
      statuses.push(r.status);
      const o = r.value;
      if (o) {
        observation = {
          stationId: id,
          stationName: station.properties.name,
          timestamp: o.timestamp ?? null,
          textDescription: o.textDescription || null,
          temperatureF: o.temperature?.value != null ? toF(o.temperature.value, o.temperature.unitCode) : null,
          dewPointF: o.dewpoint?.value != null ? toF(o.dewpoint.value, o.dewpoint.unitCode) : null,
          humidityPct: o.relativeHumidity?.value != null ? Math.round(o.relativeHumidity.value) : null,
          windMph: o.windSpeed?.value != null ? Math.round(o.windSpeed.value * 0.621371) : null,
          windDirection: o.windDirection?.value != null ? String(Math.round(o.windDirection.value)) : null,
          precipLastHourIn: o.precipitationLastHour?.value != null ? Math.round((o.precipitationLastHour.value / 25.4) * 100) / 100 : null,
        };
      }
    } else {
      statuses.push(stationsResult.status);
    }
  }

  const alertsUrl = `${NWS}/alerts/active?point=${coords}`;
  sources.alerts = alertsUrl;
  const alertsResult = await sourced("nws-alerts", "NWS alerts", alertsUrl, async () => ({ value: (await fetchJSON(alertsUrl)).data.features ?? [] }));
  statuses.push(alertsResult.status);
  const alerts = {
    state: alertsResult.ok ? "ready" : "unavailable",
    checkedAt: alertsResult.status.checkedAt,
    items: (alertsResult.value ?? []).map((f) => ({
      id: f.properties.id ?? f.id,
      event: f.properties.event,
      headline: f.properties.headline ?? null,
      severity: f.properties.severity ?? null,
      urgency: f.properties.urgency ?? null,
      onset: f.properties.onset ?? null,
      ends: f.properties.ends ?? null,
      expires: f.properties.expires ?? null,
      description: f.properties.description ?? null,
      instruction: f.properties.instruction ?? null,
      areaDesc: f.properties.areaDesc ?? null,
      url: f.id ?? null,
    })),
  };

  const uvUrl = `https://data.epa.gov/dmapservice/getEnvirofactsUVDAILY/ZIP/${point.uvZip}/JSON`;
  sources.uv = uvUrl;
  const uvResult = await sourced("epa-uv", `EPA UV · ZIP ${point.uvZip}`, uvUrl, async () => {
    const { data } = await fetchJSON(uvUrl);
    const row = Array.isArray(data) ? data[0] : null;
    if (!row) throw new Error("empty UV response");
    return { value: row, sourceTime: row.DATE ?? null };
  });
  statuses.push(uvResult.status);
  const uv = { state: uvResult.ok ? "ready" : "unavailable", checkedAt: uvResult.status.checkedAt, zip: point.uvZip,
    index: uvResult.value ? Number(uvResult.value.UV_INDEX) : null, date: uvResult.value?.DATE ?? null, alert: uvResult.value ? uvResult.value.UV_ALERT === 1 || uvResult.value.UV_ALERT === "1" : null };
  if (!uvResult.ok) uv.detail = uvResult.status.detail;

  const modelUrl = `https://api.open-meteo.com/v1/forecast?latitude=${point.latitude}&longitude=${point.longitude}&hourly=visibility,snowfall&forecast_days=2&timeformat=unixtime&timezone=GMT&models=gfs_seamless`;
  sources.models = modelUrl;
  const modelResult = await sourced("model-visibility", "Modeled visibility/snow (Open-Meteo GFS)", modelUrl, async () => ({ value: (await fetchJSON(modelUrl)).data.hourly }));
  statuses.push(modelResult.status);
  const visibility = { state: modelResult.ok ? "ready" : "unavailable", checkedAt: modelResult.status.checkedAt };
  const snowfall = { state: modelResult.ok ? "ready" : "unavailable", checkedAt: modelResult.status.checkedAt };
  if (modelResult.value) {
    const h = modelResult.value;
    const nowSec = Date.now() / 1000;
    const idx = h.time.findIndex((t) => t >= nowSec - 3600);
    const start = idx < 0 ? 0 : idx;
    const vis = h.visibility.slice(start, start + 12).filter((v) => v != null).map((m) => m / 1609.344);
    visibility.firstMiles = vis[0] ?? null;
    visibility.firstTime = new Date(h.time[start] * 1000).toISOString();
    visibility.minMiles12h = vis.length ? Math.min(...vis) : null;
    const snowCm = h.snowfall.slice(start, start + 24).reduce((a, b) => a + (b ?? 0), 0);
    snowfall.next24hIn = Math.round((snowCm / 2.54) * 10) / 10;
  } else {
    visibility.detail = snowfall.detail = modelResult.status.detail;
  }

  const airUrl = `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${point.latitude}&longitude=${point.longitude}&hourly=us_aqi,pm2_5&forecast_days=2&timeformat=unixtime&timezone=GMT`;
  sources.airQuality = airUrl;
  const airResult = await sourced("model-air", "Modeled US AQI / PM2.5 (Open-Meteo)", airUrl, async () => ({ value: (await fetchJSON(airUrl)).data.hourly }));
  statuses.push(airResult.status);
  const airQuality = { state: airResult.ok ? "ready" : "unavailable", checkedAt: airResult.status.checkedAt };
  if (airResult.value) {
    const h = airResult.value;
    const nowSec = Date.now() / 1000;
    const idx = Math.max(0, h.time.findIndex((t) => t >= nowSec - 3600));
    const aqi = h.us_aqi.slice(idx, idx + 12).filter((v) => v != null);
    airQuality.firstAqi = aqi[0] ?? null;
    airQuality.firstTime = new Date(h.time[idx] * 1000).toISOString();
    airQuality.maxAqi12h = aqi.length ? Math.max(...aqi) : null;
    airQuality.pm25 = h.pm2_5[idx] ?? null;
  } else {
    airQuality.detail = airResult.status.detail;
  }

  const nowMs = Date.now();
  const current = hourly.find((p) => Date.parse(p.end) > nowMs) ?? hourly[0] ?? null;
  return { kind: "weather", version: 1, fetchedAt: nowISO(), point, timezone: "America/Los_Angeles", forecastUpdatedAt, current, hourly, observation, alerts, uv, visibility, snowfall, airQuality, sources, statuses };
}
