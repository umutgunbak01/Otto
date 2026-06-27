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
    let key: String                 // normalized (folded) key
    let displayName: String         // pretty city name
    var coordinate: CityCoordinate?
    var connections: [Connection]
    var companies: [Company]
    var events: [Event]
    var networkEntries: [NetworkEntry]

    var id: String { key }
    var totalCount: Int { connections.count + companies.count + events.count + networkEntries.count }
    var hasCoordinate: Bool { coordinate != nil }
}

// MARK: - City Index (groups items by canonical city)

enum CityIndex {
    /// Groups every located item (connections, companies, events, network-hub
    /// entries) into one bucket per canonical city, attaching any cached
    /// coordinate. Sorted by busiest city first.
    static func build(
        connections: [Connection],
        companies: [Company],
        events: [Event],
        networkEntries: [NetworkEntry],
        coordinates: [String: CityCoordinate]
    ) -> [CityGroup] {
        var groups: [String: CityGroup] = [:]

        func ensure(_ raw: String) -> String? {
            guard let (key, display) = LocationNormalizer.canonicalCity(from: raw) else { return nil }
            if groups[key] == nil {
                groups[key] = CityGroup(
                    key: key, displayName: display, coordinate: coordinates[key],
                    connections: [], companies: [], events: [], networkEntries: []
                )
            }
            return key
        }

        for c in connections { if let k = ensure(c.location) { groups[k]?.connections.append(c) } }
        for co in companies { if let k = ensure(co.location) { groups[k]?.companies.append(co) } }
        for e in events { if let k = ensure(e.location) { groups[k]?.events.append(e) } }
        for n in networkEntries { if let k = ensure(n.location) { groups[k]?.networkEntries.append(n) } }

        return Array(groups.values).sorted { $0.totalCount > $1.totalCount }
    }

    /// Distinct (key → display) cities across all data — used to drive geocoding.
    static func uniqueCities(
        connections: [Connection],
        companies: [Company],
        events: [Event],
        networkEntries: [NetworkEntry]
    ) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ raw: String) {
            if let (key, display) = LocationNormalizer.canonicalCity(from: raw) { out[key] = display }
        }
        connections.forEach { add($0.location) }
        companies.forEach { add($0.location) }
        events.forEach { add($0.location) }
        networkEntries.forEach { add($0.location) }
        return out
    }
}

// MARK: - Canonical City table (single source for normalizer + geocoder seed)

struct CanonicalCity {
    let name: String          // pretty display, e.g. "İstanbul"
    let latitude: Double
    let longitude: Double
    let countryCode: String
    let aliases: [String]     // extra names/spellings/districts that map here
}

enum CanonicalCities {
    /// Major hubs + every city present in the user's data, with coordinates and
    /// multilingual aliases. Drives both pin placement (geocoder seed) and the
    /// "known city" test the normalizer uses to roll districts up to their city.
    static let all: [CanonicalCity] = [
        // Türkiye
        .init(name: "İstanbul", latitude: 41.0082, longitude: 28.9784, countryCode: "TR",
              aliases: ["istanbul", "constantinople", "atasehir", "besiktas", "kadikoy",
                        "sisli", "uskudar", "maslak", "levent", "sariyer", "bakirkoy",
                        "beyoglu", "kartal", "pendik", "umraniye", "fatih", "sile",
                        "beylikduzu", "maltepe", "bagcilar"]),
        .init(name: "Ankara", latitude: 39.9334, longitude: 32.8597, countryCode: "TR", aliases: []),
        .init(name: "İzmir", latitude: 38.4237, longitude: 27.1428, countryCode: "TR", aliases: ["izmir"]),
        .init(name: "Bursa", latitude: 40.1826, longitude: 29.0665, countryCode: "TR", aliases: []),
        .init(name: "Antalya", latitude: 36.8969, longitude: 30.7133, countryCode: "TR", aliases: []),
        // North America
        .init(name: "San Francisco", latitude: 37.7749, longitude: -122.4194, countryCode: "US",
              aliases: ["sf", "sfo", "san francisco bay area", "bay area", "silicon valley"]),
        .init(name: "San Jose", latitude: 37.3382, longitude: -121.8863, countryCode: "US", aliases: []),
        .init(name: "Palo Alto", latitude: 37.4419, longitude: -122.1430, countryCode: "US", aliases: []),
        .init(name: "Mountain View", latitude: 37.3861, longitude: -122.0839, countryCode: "US", aliases: []),
        .init(name: "Oakland", latitude: 37.8044, longitude: -122.2712, countryCode: "US", aliases: []),
        .init(name: "New York", latitude: 40.7128, longitude: -74.0060, countryCode: "US",
              aliases: ["nyc", "new york city", "nueva york", "manhattan", "brooklyn"]),
        .init(name: "Los Angeles", latitude: 34.0522, longitude: -118.2437, countryCode: "US", aliases: ["la"]),
        .init(name: "Seattle", latitude: 47.6062, longitude: -122.3321, countryCode: "US", aliases: []),
        .init(name: "Austin", latitude: 30.2672, longitude: -97.7431, countryCode: "US", aliases: []),
        .init(name: "Boston", latitude: 42.3601, longitude: -71.0589, countryCode: "US", aliases: ["cambridge"]),
        .init(name: "Chicago", latitude: 41.8781, longitude: -87.6298, countryCode: "US", aliases: []),
        .init(name: "Denver", latitude: 39.7392, longitude: -104.9903, countryCode: "US", aliases: []),
        .init(name: "Miami", latitude: 25.7617, longitude: -80.1918, countryCode: "US", aliases: []),
        .init(name: "Washington", latitude: 38.9072, longitude: -77.0369, countryCode: "US",
              aliases: ["washington dc", "washington d.c."]),
        .init(name: "Toronto", latitude: 43.6532, longitude: -79.3832, countryCode: "CA", aliases: []),
        .init(name: "Vancouver", latitude: 49.2827, longitude: -123.1207, countryCode: "CA", aliases: []),
        .init(name: "Mexico City", latitude: 19.4326, longitude: -99.1332, countryCode: "MX", aliases: []),
        // Europe
        .init(name: "London", latitude: 51.5074, longitude: -0.1278, countryCode: "GB", aliases: ["londra", "greater london"]),
        .init(name: "Paris", latitude: 48.8566, longitude: 2.3522, countryCode: "FR", aliases: []),
        .init(name: "Berlin", latitude: 52.5200, longitude: 13.4050, countryCode: "DE", aliases: ["brandenburg"]),
        .init(name: "Munich", latitude: 48.1351, longitude: 11.5820, countryCode: "DE", aliases: ["munchen"]),
        .init(name: "Hamburg", latitude: 53.5511, longitude: 9.9937, countryCode: "DE", aliases: []),
        .init(name: "Amsterdam", latitude: 52.3676, longitude: 4.9041, countryCode: "NL", aliases: []),
        .init(name: "Rotterdam", latitude: 51.9244, longitude: 4.4777, countryCode: "NL", aliases: []),
        .init(name: "Madrid", latitude: 40.4168, longitude: -3.7038, countryCode: "ES", aliases: []),
        .init(name: "Barcelona", latitude: 41.3851, longitude: 2.1734, countryCode: "ES", aliases: []),
        .init(name: "Lisbon", latitude: 38.7223, longitude: -9.1393, countryCode: "PT", aliases: ["lisboa"]),
        .init(name: "Dublin", latitude: 53.3498, longitude: -6.2603, countryCode: "IE", aliases: []),
        .init(name: "Zurich", latitude: 47.3769, longitude: 8.5417, countryCode: "CH", aliases: ["zürich"]),
        .init(name: "Milan", latitude: 45.4642, longitude: 9.1900, countryCode: "IT", aliases: ["milano"]),
        .init(name: "Rome", latitude: 41.9028, longitude: 12.4964, countryCode: "IT", aliases: ["roma"]),
        .init(name: "Stockholm", latitude: 59.3293, longitude: 18.0686, countryCode: "SE", aliases: []),
        .init(name: "Copenhagen", latitude: 55.6761, longitude: 12.5683, countryCode: "DK", aliases: []),
        .init(name: "Helsinki", latitude: 60.1699, longitude: 24.9384, countryCode: "FI", aliases: []),
        .init(name: "Vienna", latitude: 48.2082, longitude: 16.3738, countryCode: "AT", aliases: ["wien"]),
        .init(name: "Warsaw", latitude: 52.2297, longitude: 21.0122, countryCode: "PL", aliases: []),
        .init(name: "Brussels", latitude: 50.8503, longitude: 4.3517, countryCode: "BE", aliases: []),
        // Middle East & Africa
        .init(name: "Dubai", latitude: 25.2048, longitude: 55.2708, countryCode: "AE", aliases: []),
        .init(name: "Tel Aviv", latitude: 32.0853, longitude: 34.7818, countryCode: "IL", aliases: ["tel aviv yafo"]),
        .init(name: "Nairobi", latitude: -1.2921, longitude: 36.8219, countryCode: "KE", aliases: []),
        .init(name: "Lagos", latitude: 6.5244, longitude: 3.3792, countryCode: "NG", aliases: []),
        // Asia & Pacific
        .init(name: "Bengaluru", latitude: 12.9716, longitude: 77.5946, countryCode: "IN", aliases: ["bangalore"]),
        .init(name: "Mumbai", latitude: 19.0760, longitude: 72.8777, countryCode: "IN", aliases: ["bombay"]),
        .init(name: "Delhi", latitude: 28.6139, longitude: 77.2090, countryCode: "IN", aliases: ["new delhi"]),
        .init(name: "Singapore", latitude: 1.3521, longitude: 103.8198, countryCode: "SG", aliases: []),
        .init(name: "Hong Kong", latitude: 22.3193, longitude: 114.1694, countryCode: "HK", aliases: []),
        .init(name: "Tokyo", latitude: 35.6762, longitude: 139.6503, countryCode: "JP", aliases: []),
        .init(name: "Seoul", latitude: 37.5665, longitude: 126.9780, countryCode: "KR", aliases: []),
        .init(name: "Bangkok", latitude: 13.7563, longitude: 100.5018, countryCode: "TH", aliases: []),
        .init(name: "Sydney", latitude: -33.8688, longitude: 151.2093, countryCode: "AU", aliases: []),
        .init(name: "Melbourne", latitude: -37.8136, longitude: 144.9631, countryCode: "AU", aliases: []),
        // South America
        .init(name: "São Paulo", latitude: -23.5558, longitude: -46.6396, countryCode: "BR", aliases: ["sao paulo"]),
        .init(name: "Buenos Aires", latitude: -34.6037, longitude: -58.3816, countryCode: "AR", aliases: []),
    ]

    /// Folded name / alias → canonical city.
    static let index: [String: CanonicalCity] = {
        var m: [String: CanonicalCity] = [:]
        for c in all {
            m[LocationNormalizer.fold(c.name)] = c
            for a in c.aliases { m[LocationNormalizer.fold(a)] = c }
        }
        return m
    }()

    static func match(_ foldedToken: String) -> CanonicalCity? { index[foldedToken] }
}

// MARK: - Location Normalizer

/// Collapses messy, multilingual free-text locations onto one canonical city so
/// they share a single map pin. Handles diacritics and Turkish dotted/dotless I
/// ("İstanbul" ≡ "Istanbul"), strips country/region/district parts in several
/// languages ("İstanbul, İstanbul, Türkiye" → İstanbul; "Ataşehir, İstanbul" →
/// İstanbul), and aliases non-English names ("Londra" → London). Returns
/// `(key, display)` or nil for blanks / country-only / non-geographic values.
enum LocationNormalizer {
    static func canonicalCity(from raw: String) -> (key: String, display: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = splitParts(trimmed)
        guard !parts.isEmpty else { return nil }

        // 1) A known city anywhere in the parts wins (handles "District, City,
        //    Country" and "City, State, Country" uniformly).
        for p in parts {
            if let city = CanonicalCities.match(fold(stripNoise(p))) {
                return (fold(city.name), city.name)
            }
        }

        // 2) No known city — drop trailing country/region terms, keep the rest.
        var remaining = parts
        while remaining.count > 1, isRegionTerm(fold(stripNoise(remaining[remaining.count - 1]))) {
            remaining.removeLast()
        }
        let candidate = stripNoise(remaining.first ?? parts[0])
        let folded = fold(candidate)
        guard !candidate.isEmpty, !isRegionTerm(folded), !ignored.contains(folded) else { return nil }

        if let city = CanonicalCities.match(folded) {
            return (fold(city.name), city.name)
        }
        return (folded, titleCased(candidate))
    }

    /// Turkish-aware lowercasing + diacritic removal, so "İstanbul", "Istanbul"
    /// and "istanbul" fold to the same key.
    static func fold(_ s: String) -> String {
        var t = s
            .replacingOccurrences(of: "İ", with: "i")
            .replacingOccurrences(of: "I", with: "i")
            .replacingOccurrences(of: "ı", with: "i")
        t = t.lowercased()
        t = t.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        return t.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func splitParts(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "/", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func stripNoise(_ token: String) -> String {
        var t = token.trimmingCharacters(in: .whitespaces)
        for prefix in noisePrefixes where fold(t).hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        var changed = true
        while changed {
            changed = false
            for suffix in noiseSuffixes where fold(t).hasSuffix(suffix) {
                t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return t
    }

    private static func titleCased(_ s: String) -> String {
        let isAllUpper = s == s.uppercased()
        let isAllLower = s == s.lowercased()
        if isAllUpper || isAllLower { return s.capitalized }
        return s
    }

    private static func isRegionTerm(_ folded: String) -> Bool { regionTerms.contains(folded) }

    // Prefix/suffix noise (folded, lower-case ASCII).
    private static let noisePrefixes = ["greater ", "metropolitan ", "metropolregion ", "metro ", "grand "]
    private static let noiseSuffixes = [
        " bay area", " metropolitan area", " metropolitan region", " metropolitan",
        " metro area", " metro", " metropol bolgesi", " bolgesi", " region", " area",
        " district", " county", " province", " et peripherie", " und umgebung",
        " e dintorni", " y alrededores", " emirligi", " emirate"
    ]

    /// Non-geographic values to drop entirely.
    private static let ignored: Set<String> = Set([
        "remote", "worldwide", "global", "earth", "europe", "european union",
        "asia", "north america", "south america", "africa", "internet", "n/a", "none"
    ].map(fold))

    /// Country / state / province names (multilingual) — stripped as trailing
    /// parts, and treated as country-only (skipped) when alone. City-states
    /// (Singapore, Hong Kong) are deliberately absent — they're cities.
    private static let regionTerms: Set<String> = Set([
        // English
        "United States", "USA", "US", "United Kingdom", "UK", "England", "Scotland",
        "Wales", "Northern Ireland", "Great Britain", "Germany", "France", "Netherlands",
        "Holland", "Israel", "Austria", "Spain", "Italy", "Canada", "Turkey", "Türkiye",
        "Ireland", "Switzerland", "Sweden", "Denmark", "Norway", "Finland", "Poland",
        "Belgium", "Portugal", "Greece", "Czechia", "Czech Republic", "Australia",
        "Brazil", "Mexico", "Argentina", "India", "China", "Japan", "South Korea",
        "United Arab Emirates", "UAE", "Kenya", "Nigeria", "South Africa", "Thailand",
        // US states / regions seen in data
        "California", "Texas", "Florida", "Illinois", "Massachusetts", "New Jersey",
        "Pennsylvania", "Delaware", "Bavaria", "North Holland", "Île-de-France",
        "Catalonia",
        // Turkish
        "Birleşik Devletler", "Birleşik Krallık", "İngiltere", "Hollanda", "Almanya",
        "Fransa", "Kuzey Hollanda", "Kaliforniya", "İspanya", "İtalya", "Avusturya",
        "İsviçre", "Kanada", "İsrail", "Yunanistan", "İrlanda",
        // Spanish / French / German / Italian
        "Estados Unidos", "Reino Unido", "Alemania", "Francia", "España", "Países Bajos",
        "Österreich", "Deutschland", "Bayern", "Frankreich", "Italia"
    ].map(fold))
}
