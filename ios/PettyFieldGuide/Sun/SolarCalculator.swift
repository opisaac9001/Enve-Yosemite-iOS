import Foundation
import CoreLocation

/// NOAA solar position equations (Meeus-based), computed on device, no network.
enum SolarCalculator {
    struct DayTimes: Sendable {
        var sunrise: Date?
        var solarNoon: Date
        var sunset: Date?
        var civilDawn: Date?
        var civilDusk: Date?
    }

    struct Position: Sendable {
        var altitude: Double   // degrees above horizon
        var azimuth: Double    // degrees clockwise from north
    }

    enum Phase: String, Sendable {
        case day, civilTwilight, nauticalTwilight, astronomicalTwilight, night
        var title: String {
            switch self {
            case .day: "Daylight"
            case .civilTwilight: "Civil twilight"
            case .nauticalTwilight: "Nautical twilight"
            case .astronomicalTwilight: "Astronomical twilight"
            case .night: "Night"
            }
        }
    }

    static func phase(forAltitude altitude: Double) -> Phase {
        if altitude >= -0.833 { return .day }
        if altitude >= -6 { return .civilTwilight }
        if altitude >= -12 { return .nauticalTwilight }
        if altitude >= -18 { return .astronomicalTwilight }
        return .night
    }

    private static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2_440_587.5
    }

    private static func julianCentury(_ jd: Double) -> Double { (jd - 2_451_545) / 36525 }

    private struct Ephemeris {
        var declination: Double  // radians
        var eqTime: Double       // minutes
    }

    private static func ephemeris(julianCentury t: Double) -> Ephemeris {
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let mr = m * .pi / 180
        let c = sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * mr) * (0.019993 - 0.000101 * t) + sin(3 * mr) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let apparentLong = trueLong - 0.00569 - 0.00478 * sin(omega * .pi / 180)
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(omega * .pi / 180)
        let epsR = eps * .pi / 180
        let decl = asin(sin(epsR) * sin(apparentLong * .pi / 180))
        let y = tan(epsR / 2) * tan(epsR / 2)
        let l0r = l0 * .pi / 180
        let eqTime = 4 * (y * sin(2 * l0r) - 2 * e * sin(mr) + 4 * e * y * sin(mr) * cos(2 * l0r)
                          - 0.5 * y * y * sin(4 * l0r) - 1.25 * e * e * sin(2 * mr)) * 180 / .pi
        return Ephemeris(declination: decl, eqTime: eqTime)
    }

    static func position(at date: Date, coordinate: CLLocationCoordinate2D) -> Position {
        let t = julianCentury(julianDay(date))
        let eph = ephemeris(julianCentury: t)
        let minutesUTC = (date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400)) / 60
        var trueSolarTime = (minutesUTC + eph.eqTime + 4 * coordinate.longitude).truncatingRemainder(dividingBy: 1440)
        if trueSolarTime < 0 { trueSolarTime += 1440 }
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }
        let haR = hourAngle * .pi / 180
        let latR = coordinate.latitude * .pi / 180
        let cosZenith = sin(latR) * sin(eph.declination) + cos(latR) * cos(eph.declination) * cos(haR)
        let zenith = acos(max(-1, min(1, cosZenith)))
        let altitude = 90 - zenith * 180 / .pi
        var azimuth: Double
        let denom = cos(latR) * sin(zenith)
        if abs(denom) > 1e-9 {
            var azR = acos(max(-1, min(1, (sin(latR) * cos(zenith) - sin(eph.declination)) / denom)))
            azR = .pi - azR
            azimuth = azR * 180 / .pi
            if hourAngle > 0 { azimuth = (azimuth + 180).truncatingRemainder(dividingBy: 360) } else { azimuth = (540 - azimuth).truncatingRemainder(dividingBy: 360) }
        } else {
            azimuth = coordinate.latitude > 0 ? 180 : 0
        }
        // Atmospheric refraction correction for the reported altitude.
        let refraction: Double
        if altitude > 85 { refraction = 0 } else {
            let te = tan(altitude * .pi / 180)
            if altitude > 5 { refraction = (58.1 / te - 0.07 / pow(te, 3) + 0.000086 / pow(te, 5)) / 3600 }
            else if altitude > -0.575 { refraction = (1735 + altitude * (-518.2 + altitude * (103.4 + altitude * (-12.79 + altitude * 0.711)))) / 3600 }
            else { refraction = (-20.774 / te) / 3600 }
        }
        return Position(altitude: altitude + refraction, azimuth: azimuth)
    }

    /// Sunrise/sunset at the standard zenith of 90.833°; civil twilight at 96°.
    static func dayTimes(on date: Date, at coordinate: CLLocationCoordinate2D, timeZone: TimeZone) -> DayTimes {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let localMidnight = cal.startOfDay(for: date)
        let noonGuess = localMidnight.addingTimeInterval(12 * 3600)
        let t = julianCentury(julianDay(noonGuess))
        let eph = ephemeris(julianCentury: t)
        let solarNoonMinutesUTC = 720 - 4 * coordinate.longitude - eph.eqTime
        let utcDayStart = Date(timeIntervalSince1970: floor(noonGuess.timeIntervalSince1970 / 86400) * 86400)
        let solarNoon = utcDayStart.addingTimeInterval(solarNoonMinutesUTC * 60)

        func hourAngle(zenith: Double) -> Double? {
            let latR = coordinate.latitude * .pi / 180
            let zR = zenith * .pi / 180
            let cosHA = (cos(zR) / (cos(latR) * cos(eph.declination))) - tan(latR) * tan(eph.declination)
            guard cosHA >= -1 && cosHA <= 1 else { return nil }
            return acos(cosHA) * 180 / .pi
        }
        func event(zenith: Double, rising: Bool) -> Date? {
            guard let ha = hourAngle(zenith: zenith) else { return nil }
            let minutes = solarNoonMinutesUTC + (rising ? -ha * 4 : ha * 4)
            return utcDayStart.addingTimeInterval(minutes * 60)
        }
        return DayTimes(sunrise: event(zenith: 90.833, rising: true),
                        solarNoon: solarNoon,
                        sunset: event(zenith: 90.833, rising: false),
                        civilDawn: event(zenith: 96, rising: true),
                        civilDusk: event(zenith: 96, rising: false))
    }

    static func compassName(forAzimuth azimuth: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return names[Int((azimuth + 11.25).truncatingRemainder(dividingBy: 360) / 22.5) % 16]
    }
}
