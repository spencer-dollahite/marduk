import Foundation

/// The daily brief's weather segment, against open-meteo.com — KEYLESS
/// and free, chosen over Apple WeatherKit because WeatherKit needs an
/// entitlement and a developer account at RUN time, which a background
/// daemon a stranger installed from a DMG cannot assume.
///
/// Location is CONFIG, never CoreLocation: asking for the Location
/// permission to say "72 degrees" is a bad trade, and `:config place
/// <city>` geocodes through the same keyless service, so the user never
/// has to know or speak a decimal coordinate.
///
/// Everything here is pure — URL building, JSON parsing, and wording.
/// The curl call lives in `BriefReader`.
enum Weather {

    struct Report: Equatable {
        var temperature: Double
        var apparent: Double?
        var code: Int?
        var high: Double?
        var low: Double?
        var precipitationChance: Int?
    }

    /// One geocoded place: what `:config place` stores.
    struct Place: Equatable {
        var name: String
        var region: String?     // admin1 — "Utah"
        var country: String?
        var latitude: Double
        var longitude: Double

        /// "Salt Lake City, Utah" — what the brief says. The country is
        /// dropped when a region exists; "Salt Lake City, Utah, United
        /// States" is a mailing address, not a spoken weather report.
        var spokenName: String {
            if let region, !region.isEmpty { return "\(name), \(region)" }
            if let country, !country.isEmpty { return "\(name), \(country)" }
            return name
        }
    }

    // MARK: - URLs

    /// Only what a URL query value may carry. `.urlQueryAllowed` lets `&`
    /// and `=` through, which would let a place name rewrite the query.
    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    static func geocodeURL(query: String) -> String {
        "https://geocoding-api.open-meteo.com/v1/search?name="
            + encode(query) + "&count=1&language=en&format=json"
    }

    /// Celsius/kilometres are open-meteo's defaults, so metric asks for
    /// nothing and imperial names its units explicitly.
    static func forecastURL(latitude: Double, longitude: Double,
                            metric: Bool) -> String {
        var url = "https://api.open-meteo.com/v1/forecast"
            + "?latitude=\(latitude)&longitude=\(longitude)"
            + "&current=temperature_2m,apparent_temperature,weather_code"
            + "&daily=temperature_2m_max,temperature_2m_min,"
            + "precipitation_probability_max"
            + "&timezone=auto&forecast_days=1"
        if !metric {
            url += "&temperature_unit=fahrenheit&wind_speed_unit=mph"
                + "&precipitation_unit=inch"
        }
        return url
    }

    // MARK: - Parsing

    static func parse(forecastJSON data: Data) -> Report? {
        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = number(current["temperature_2m"]) else {
            return nil
        }
        let daily = root["daily"] as? [String: Any]
        return Report(
            temperature: temperature,
            apparent: number(current["apparent_temperature"]),
            code: number(current["weather_code"]).map { Int($0) },
            high: firstNumber(daily?["temperature_2m_max"]),
            low: firstNumber(daily?["temperature_2m_min"]),
            precipitationChance: firstNumber(daily?["precipitation_probability_max"])
                .map { Int($0) })
    }

    static func parse(geocodingJSON data: Data) -> Place? {
        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let name = first["name"] as? String,
              let latitude = number(first["latitude"]),
              let longitude = number(first["longitude"]) else {
            return nil
        }
        return Place(name: name,
                     region: first["admin1"] as? String,
                     country: first["country"] as? String,
                     latitude: latitude,
                     longitude: longitude)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func firstNumber(_ value: Any?) -> Double? {
        number((value as? [Any])?.first)
    }

    // MARK: - Wording

    /// WMO weather-interpretation codes, the vocabulary open-meteo speaks.
    /// A TABLE, like every other per-source quirk in this product. An
    /// unknown code degrades to no description rather than a number the
    /// user cannot act on.
    static let codeWords: [Int: String] = [
        0: "clear", 1: "mainly clear", 2: "partly cloudy", 3: "overcast",
        45: "foggy", 48: "freezing fog",
        51: "light drizzle", 53: "drizzle", 55: "heavy drizzle",
        56: "light freezing drizzle", 57: "freezing drizzle",
        61: "light rain", 63: "rain", 65: "heavy rain",
        66: "light freezing rain", 67: "freezing rain",
        71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains",
        80: "light rain showers", 81: "rain showers",
        82: "violent rain showers",
        85: "light snow showers", 86: "snow showers",
        95: "thunderstorms", 96: "thunderstorms with hail",
        99: "thunderstorms with heavy hail",
    ]

    static func description(code: Int?) -> String? {
        code.flatMap { codeWords[$0] }
    }

    /// Whole degrees: a brief is spoken, and "72 point 3 degrees" is
    /// noise nobody dresses by.
    static func degrees(_ value: Double) -> String {
        "\(Int(value.rounded())) degrees"
    }

    /// "Weather in Salt Lake City. 72 degrees, partly cloudy. Feels like
    /// 70. A high of 95 and a low of 68, with a 10 percent chance of rain."
    static func spoken(_ report: Report, place: String?) -> String {
        var sentences: [String] = []
        let location = place.map { " in \($0)" } ?? ""
        if let sky = description(code: report.code) {
            sentences.append("Weather\(location). "
                + "\(degrees(report.temperature)), \(sky).")
        } else {
            sentences.append("Weather\(location). "
                + "\(degrees(report.temperature)).")
        }
        // Only when it disagrees enough to be worth a sentence — a "feels
        // like" one degree off the reading is filler.
        if let apparent = report.apparent,
           abs(apparent - report.temperature) >= 3 {
            sentences.append("Feels like \(degrees(apparent)).")
        }
        if let high = report.high, let low = report.low {
            var today = "A high of \(degrees(high)) and a low of "
                + "\(degrees(low))"
            if let chance = report.precipitationChance, chance >= 10 {
                today += ", with a \(chance) percent chance of rain"
            }
            sentences.append(today + ".")
        }
        return sentences.joined(separator: " ")
    }
}
