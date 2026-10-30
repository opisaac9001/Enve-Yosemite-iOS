import Foundation

/// Per-source state carried by every feed. `state` is ready | unavailable | unknown.
struct FeedStatus: Codable, Hashable, Identifiable, Sendable {
    var key: String
    var label: String
    var state: String
    var checkedAt: String
    var url: String?
    var detail: String?
    var sourceTime: String?
    var id: String { key }

    var sourceState: SourceState {
        switch state {
        case "ready": .ready
        case "unavailable": .unavailable
        default: .unknown
        }
    }
}

struct NoticeItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: String?            // road | roadwork | trail | alert | wilderness | roadevent; absent on raw NPS alerts
    var title: String
    var statusText: String?
    var status: String?
    var text: String?
    var area: String?
    var subjects: [String]?
    var url: String?
    var sourceDate: String?
    var reportDate: String?
    var start: String?
    var end: String?
    var category: String?
    var description: String?
    var lastModified: String?
    var startDate: String?
    var endDate: String?

    var body: String { text ?? description ?? "" }
    var dated: String? { sourceDate ?? lastModified ?? reportDate }
}

struct NoticeList: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var items: [NoticeItem]
    var url: String?
    var label: String?
    var pageUpdated: String?
    var reportDate: String?
    var roadTableFound: Bool?
    var roadTableNote: String?
    var trailsFound: Bool?
    var roadworkFound: Bool?
    var keyed: Bool?
    var feedUpdated: String?
    var fireMatches: [String]?
}

// MARK: Weather

struct HourlyPeriod: Codable, Hashable, Sendable {
    var start: String
    var end: String
    var isDaytime: Bool
    var temperatureF: Double?
    var dewPointF: Double?
    var humidityPct: Double?
    var windMph: Double?
    var windDirection: String?
    var precipChancePct: Double?
    var shortForecast: String?
}

struct Observation: Codable, Hashable, Sendable {
    var stationId: String
    var stationName: String
    var timestamp: String?
    var textDescription: String?
    var temperatureF: Double?
    var dewPointF: Double?
    var humidityPct: Double?
    var windMph: Double?
    var windDirection: String?
    var precipLastHourIn: Double?
}

struct AlertItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var event: String
    var headline: String?
    var severity: String?
    var urgency: String?
    var onset: String?
    var ends: String?
    var expires: String?
    var description: String?
    var instruction: String?
    var areaDesc: String?
    var url: String?
}

struct AlertList: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var items: [AlertItem]
    var fireMatches: [String]?
}

struct UVReading: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var index: Double?
    var date: String?
    var alert: Bool?
    var zip: String?
    var detail: String?
}

struct VisibilityReading: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var firstMiles: Double?
    var firstTime: String?
    var minMiles12h: Double?
    var detail: String?
}

struct SnowReading: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var next24hIn: Double?
    var detail: String?
}

struct AirReading: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var firstAqi: Double?
    var firstTime: String?
    var maxAqi12h: Double?
    var pm25: Double?
    var detail: String?
}

struct WeatherFeed: Codable, Hashable, Sendable {
    var kind: String
    var version: Int
    var fetchedAt: String
    var point: ForecastPoint
    var timezone: String
    var forecastUpdatedAt: String?
    var current: HourlyPeriod?
    var hourly: [HourlyPeriod]
    var observation: Observation?
    var alerts: AlertList
    var uv: UVReading
    var visibility: VisibilityReading
    var snowfall: SnowReading
    var airQuality: AirReading
    var sources: [String: String]
    var statuses: [FeedStatus]
}

// MARK: Fire

struct FireAssessment: Codable, Hashable, Sendable {
    var priority: Int
    var label: String
    var reasons: [String]
    var inputs: [String: String]
    var heuristicNote: String
}

struct FireMetrics: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var hoursCovered: Int?
    var minHumidityPct: Double?
    var maxTemperatureF: Double?
    var maxWindMph: Double?
    var maxPrecipChancePct: Double?
    var thunderHours: Int?
    var windowStart: String?
    var windowEnd: String?
    var detail: String?
}

struct FireRestrictions: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var text: String?
    var pageUpdated: String?
    var url: String
    var detail: String?
}

struct FireWeatherPeriod: Codable, Hashable, Sendable {
    var name: String
    var skyWeather: String?
    var thunder: String?
    var maxTemperature: String?
    var minTemperature: String?
    var minHumidity: String?
    var maxHumidity: String?
    var wettingRain: String?
    var windsSlopes: String?
    var windsRidges: String?
}

struct FireWeatherForecast: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var issuedAt: String?
    var url: String?
    var discussion: String?
    var zone: String?
    var zoneName: String?
    var periods: [FireWeatherPeriod]?
    var detail: String?
}

struct FireFeed: Codable, Hashable, Sendable {
    var kind: String
    var version: Int
    var fetchedAt: String
    var assessment: FireAssessment
    var metrics: FireMetrics
    var restrictions: FireRestrictions
    var fwf: FireWeatherForecast
    var notices: NoticeList
    var alerts: AlertList
    var statuses: [FeedStatus]
}

// MARK: Smoke

struct AirMonitorReading: Codable, Hashable, Sendable {
    var site: String
    var parameter: String
    var aqi: Double?
    var category: String?
    var value: Double?
    var units: String?
    var observedAt: String?
    var agency: String?
    var method: String?
    var latitude: Double?
    var longitude: Double?
}

struct MonitorBlock: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var dataDate: String?
    var readings: [AirMonitorReading]
    var forecasts: [AirMonitorReading]?
    var url: String?
    var detail: String?
}

struct SmokePoint: Codable, Hashable, Sendable {
    var pointKey: String
    var label: String
    var density: String?
    var observedAt: String?
}

struct SmokePolygon: Codable, Hashable, Sendable {
    var density: String
    var start: String?
    var end: String?
    var ring: [[Double]]           // [lon, lat]
    var holes: [[[Double]]]?
}

struct PlumeBlock: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var analysisDate: String?
    var url: String?
    var points: [SmokePoint]?
    var polygonsChecked: Int?
    var polygons: [SmokePolygon]?
    var detail: String?
}

struct Hotspot: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var acquiredAt: String
    var satellite: String?
    var confidence: String?
    var frpMw: Double?
    var daytime: Bool?
    var incidentId: String?
}

struct HotspotBlock: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var windowHours: Int?
    var bbox: [Double]?
    var items: [Hotspot]
    var latestAt: String?
    var unattributed: Int?
    var sources: [String]?
    var url: String?
    var detail: String?
}

struct FireIncident: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var source: String?
    var type: String?
    var acres: Double?
    var percentContained: Double?
    var discoveredAt: String?
    var updatedAt: String?
    var latitude: Double
    var longitude: Double
    var distanceMiles: Double?
    var bearing: String?
    var county: String?
    var url: String?
    var inciwebUrl: String?
    var perimeterAcres: Double?
    var hotspotCount: Int?
    var latestHotspotAt: String?
}

struct IncidentBlock: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var radiusMiles: Double?
    var items: [FireIncident]
    var sources: [String: String]?
    var detail: String?
}

struct FirePerimeter: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var acres: Double?
    var percentContained: Double?
    var updatedAt: String?
    var rings: [[[Double]]]        // [lon, lat]
}

struct PerimeterBlock: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var items: [FirePerimeter]
    var url: String?
    var detail: String?
}

struct TrackingPoint: Codable, Hashable, Sendable {
    var t: String
    var acres: Double?
    var perimeterAcres: Double?
    var percentContained: Double?
    var detections12h: Int?
}

struct TrackedIncident: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var points: [TrackingPoint]
}

struct TrackingBlock: Codable, Hashable, Sendable {
    var since: String?
    var incidents: [TrackedIncident]
    var previousPerimeters: [FirePerimeter]?
}

struct SmokeFeed: Codable, Hashable, Sendable {
    var kind: String
    var version: Int
    var fetchedAt: String
    var monitors: MonitorBlock
    var airnow: MonitorBlock
    var plumes: PlumeBlock
    var hotspots: HotspotBlock
    var incidents: IncidentBlock
    var perimeters: PerimeterBlock
    var tracking: TrackingBlock?
    var statuses: [FeedStatus]
}

// MARK: Seasonal

struct RiverReading: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var siteId: String?
    var siteName: String?
    var dischargeCfs: Double?
    var dischargeTime: String?
    var stageFt: Double?
    var stageTime: String?
    var provisional: Bool?
    var url: String?
    var detail: String?
}

struct ChainDistrict: Codable, Hashable, Sendable {
    var id: String
    var state: String
    var checkedAt: String
    var signsChecked: Int?
    var feedRecordedAt: String?
    var detail: String?
}

struct ChainControl: Codable, Hashable, Sendable {
    var route: String
    var district: String?
    var location: String?
    var requirement: String?
    var text: String?
    var recordedAt: String?
}

struct ChainBlock: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var districts: [ChainDistrict]
    var activeControls: [ChainControl]
    var signsChecked: Int?
    var routes: [String]
    var detail: String?
}

struct SeasonalFeed: Codable, Hashable, Sendable {
    var kind: String
    var version: Int
    var fetchedAt: String
    var notices: NoticeList
    var river: RiverReading
    var chains: ChainBlock
    var statuses: [FeedStatus]
}

// MARK: NPS programs

struct NPSHours: Codable, Hashable, Sendable {
    struct Exception: Codable, Hashable, Sendable {
        var name: String
        var startDate: String?
        var endDate: String?
        var hours: [String: String]
    }
    var name: String
    var description: String?
    var standard: [String: String]
    var exceptions: [Exception]
}

struct NPSVisitorCenter: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var url: String?
    var hours: [NPSHours]
    var lastIndexed: String?
}

struct NPSVisitorCenterBlock: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var items: [NPSVisitorCenter]
    var detail: String?
}

struct NPSEventTime: Codable, Hashable, Sendable {
    var start: String?
    var end: String?
    var startMinutes: Int?
    var sunriseStart: Bool?
    var sunsetEnd: Bool?
}

struct NPSEvent: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var eventId: String?
    var title: String
    var types: [String]
    var description: String?
    var location: String?
    var dates: [String]
    var cancelledDates: [String]?
    var times: [NPSEventTime]
    var allDay: Bool?
    var recurring: Bool?
    var recurrenceRule: String?
    var excludedDates: [String]?
    var seriesStart: String?
    var seriesEnd: String?
    var isFree: Bool?
    var feeInfo: String?
    var registrationRequired: Bool?
    var registrationInfo: String?
    var registrationUrl: String?
    var infoUrl: String?
    var timeInfo: String?
    var created: String?
    var updated: String?
    var url: String?
}

struct NPSEventBlock: Codable, Hashable, Sendable {
    var state: String
    var checkedAt: String
    var items: [NPSEvent]
    var total: Int?
    var url: String?
    var detail: String?
}

struct ProgramsFeed: Codable, Hashable, Sendable {
    struct Window: Codable, Hashable, Sendable { var start: String; var end: String; var days: Int }
    var kind: String
    var version: Int
    var fetchedAt: String
    var window: Window
    var visitorCenters: NPSVisitorCenterBlock
    var events: NPSEventBlock
    var statuses: [FeedStatus]
}

// MARK: Conditions (roads, trails, alerts, wilderness)

struct ConditionsFeed: Codable, Hashable, Sendable {
    var kind: String
    var version: Int
    var fetchedAt: String
    var page: NoticeList
    var roadEvents: NoticeList
    var alerts: NoticeList
    var wilderness: NoticeList
    var statuses: [FeedStatus]

    var allItems: [NoticeItem] { page.items + roadEvents.items + alerts.items + wilderness.items }
}

// MARK: Updates

struct UpdateChannel: Codable, Hashable, Sendable {
    var revision: String
    var changedAt: String?
    var checkedAt: String?
    var available: Bool
}

struct UpdatesFeed: Codable, Hashable, Sendable {
    var channels: [String: UpdateChannel]
    var pushReady: Bool
    var checkerMinutes: Int?
    var serverVersion: String?
}
