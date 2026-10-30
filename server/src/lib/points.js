/** Forecast points mirrored from the app's bundled status pack. */
export const FORECAST_POINTS = [
  { key: "valley", label: "Yosemite Valley", region: "Yosemite Village area", latitude: 37.748, longitude: -119.588, uvZip: "95389", elevationFt: 3970 },
  { key: "glacier-point", label: "Glacier Point", region: "Glacier Point Road", latitude: 37.7281, longitude: -119.573, uvZip: "95389", elevationFt: 7214 },
  { key: "tuolumne-meadows", label: "Tuolumne Meadows", region: "Tioga Road", latitude: 37.8742, longitude: -119.3581, uvZip: "93541", elevationFt: 8600 },
  { key: "wawona", label: "Wawona", region: "Wawona & Mariposa Grove", latitude: 37.5372, longitude: -119.6554, uvZip: "95389", elevationFt: 4000 },
  { key: "hetch-hetchy", label: "Hetch Hetchy", region: "Hetch Hetchy", latitude: 37.9466, longitude: -119.7881, uvZip: "95321", elevationFt: 3800 },
  { key: "crane-flat", label: "Crane Flat", region: "Big Oak Flat Road", latitude: 37.753, longitude: -119.7968, uvZip: "95389", elevationFt: 6200 },
  { key: "el-portal", label: "El Portal", region: "Highway 140", latitude: 37.6752, longitude: -119.7826, uvZip: "95318", elevationFt: 2000 },
];

export const pointByKey = (key) => FORECAST_POINTS.find((p) => p.key === key);
