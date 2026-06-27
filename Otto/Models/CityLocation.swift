import Foundation
import CoreLocation

// MARK: - City Coordinate (cached geocode result)

struct CityCoordinate: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var resolvedName: String?
    var countryCode: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - City Group (a map pin: everything you know in one city)

struct CityGroup: Identifiable {
    let key: String                 // normalized lowercase key
    let displayName: String         // pretty city name
    var coordinate: CityCoordinate?
    var connections: [Connection]
    var companies: [Company]
    var events: [Event]

    var id: String { key }
    var totalCount: Int { connections.count + companies.count + events.count }
    var hasCoordinate: Bool { coordinate != nil }
}

// MARK: - City Index (groups items by canonical city)

enum CityIndex {
    /// Groups connections, companies and events into one bucket per canonical
    /// city, attaching any cached coordinate. Sorted by busiest city first.
    static func build(
        connections: [Connection],
        companies: [Company],
        events: [Event],
        coordinates: [String: CityCoordinate]
    ) -> [CityGroup] {
        var groups: [String: CityGroup] = [:]

        func ensure(_ raw: String) -> String? {
            guard let (key, display) = LocationNormalizer.canonicalCity(from: raw) else { return nil }
            if groups[key] == nil {
                groups[key] = CityGroup(
                    key: key,
                    displayName: display,
                    coordinate: coordinates[key],
                    connections: [],
                    companies: [],
                    events: []
                )
            }
            return key
        }

        for c in connections {
            if let key = ensure(c.location) { groups[key]?.connections.append(c) }
        }
        for co in companies {
            if let key = ensure(co.location) { groups[key]?.companies.append(co) }
        }
        for e in events {
            if let key = ensure(e.location) { groups[key]?.events.append(e) }
        }

        return Array(groups.values).sorted { $0.totalCount > $1.totalCount }
    }

    /// Distinct (key → display) cities across all data — used to drive geocoding.
    static func uniqueCities(
        connections: [Connection],
        companies: [Company],
        events: [Event]
    ) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ raw: String) {
            if let (key, display) = LocationNormalizer.canonicalCity(from: raw) {
                out[key] = display
            }
        }
        connections.forEach { add($0.location) }
        companies.forEach { add($0.location) }
        events.forEach { add($0.location) }
        return out
    }
}

// MARK: - Location Normalizer

/// Collapses messy free-text locations ("San Francisco Bay Area", "SF",
/// "San Francisco, CA, USA") onto one canonical city so they share a single
/// map pin. Returns `(key, display)` or nil for blanks/remote.
enum LocationNormalizer {
    static func canonicalCity(from raw: String) -> (key: String, display: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Drop non-geographic noise values commonly seen in LinkedIn exports.
        let lowerFull = trimmed.lowercased()
        if ignored.contains(lowerFull) { return nil }

        // Whole-string alias (e.g. "san francisco bay area" → San Francisco).
        if let alias = aliases[lowerFull] {
            return (alias.lowercased(), alias)
        }

        // Take the first comma component ("San Francisco, CA" → "San Francisco").
        var city = trimmed
            .split(separator: ",")
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? trimmed

        city = stripNoise(city)

        // Re-check alias on the cleaned token ("sf" → San Francisco).
        let lower = city.lowercased()
        if let alias = aliases[lower] {
            return (alias.lowercased(), alias)
        }

        guard !city.isEmpty else { return nil }
        let display = titleCased(city)
        return (display.lowercased(), display)
    }

    private static func stripNoise(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespaces)

        for prefix in ["Greater ", "Metropolitan ", "Metro "] {
            if s.lowercased().hasPrefix(prefix.lowercased()) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Longest suffixes first so " Bay Area" wins over " Area".
        for suffix in [" Bay Area", " Metropolitan Area", " Metro Area",
                       " and Bay Area", " Metropolitan", " Region",
                       " Area", " Metro", " County"] {
            if s.lowercased().hasSuffix(suffix.lowercased()) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return s
    }

    private static func titleCased(_ s: String) -> String {
        let isAllUpper = s == s.uppercased()
        let isAllLower = s == s.lowercased()
        if isAllUpper || isAllLower { return s.capitalized }
        return s   // preserve intentional mixed case (e.g. "São Paulo")
    }

    /// Values that aren't real cities — skip them entirely.
    private static let ignored: Set<String> = [
        "remote", "worldwide", "global", "earth", "united states", "usa",
        "united kingdom", "uk", "europe", "european union", "asia",
        "north america", "south america", "africa", "internet", "n/a", "none"
    ]

    /// High-frequency ambiguous strings → canonical city.
    private static let aliases: [String: String] = [
        "sf": "San Francisco",
        "sfo": "San Francisco",
        "san francisco bay area": "San Francisco",
        "bay area": "San Francisco",
        "silicon valley": "San Francisco",
        "nyc": "New York",
        "new york city": "New York",
        "new york city metropolitan area": "New York",
        "la": "Los Angeles",
        "greater los angeles": "Los Angeles",
        "sg": "Singapore",
        "blr": "Bengaluru",
        "bangalore": "Bengaluru",
        "bombay": "Mumbai",
        "washington dc": "Washington",
        "washington d.c.": "Washington",
        "d.c.": "Washington"
    ]
}
