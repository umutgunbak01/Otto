import Foundation
import CoreLocation

/// Resolves canonical city names to coordinates for the location map.
///
/// Lookup order: in-memory/disk cache → built-in seed table (instant, offline)
/// → `CLGeocoder` network lookup (throttled, then cached forever). The cache
/// lives in its own JSON file, fully isolated from `otto_data.json`, so it
/// never risks the main data store. We only ever geocode place *names*, so no
/// location permission is required.
actor CityGeocoder {
    static let shared = CityGeocoder()

    private let geocoder = CLGeocoder()
    private var cache: [String: CityCoordinate]
    private let cacheURL: URL
    private var lastNetworkRequest: Date?

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Otto", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("city_geocode_cache.json")

        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: CityCoordinate].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    /// Resolve one city. `key` is the normalized lowercase key (also the cache
    /// key); `display` is the pretty name used for the geocoding query.
    func coordinate(key: String, display: String) async -> CityCoordinate? {
        if let cached = cache[key] { return cached }

        if let seed = Self.seed[key] {
            cache[key] = seed
            persist()
            return seed
        }

        await throttle()
        do {
            let placemarks = try await geocoder.geocodeAddressString(display)
            if let pm = placemarks.first, let loc = pm.location {
                let coord = CityCoordinate(
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    resolvedName: pm.locality ?? pm.name ?? display,
                    countryCode: pm.isoCountryCode
                )
                cache[key] = coord
                persist()
                return coord
            }
        } catch {
            // Network failure / not found → leave unresolved; retried next session.
        }
        return nil
    }

    /// Apple rate-limits `CLGeocoder`; keep network requests to ~1/sec.
    private func throttle() async {
        if let last = lastNetworkRequest {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 1.0 {
                try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
            }
        }
        lastNetworkRequest = Date()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Seed table

    /// Major world cities → coordinates. Keys are lower-cased to match the
    /// normalizer's output. Covers the common tech/startup hubs so the most
    /// frequent pins appear instantly with zero network calls.
    static let seed: [String: CityCoordinate] = {
        let raw: [(String, Double, Double, String)] = [
            // North America
            ("San Francisco", 37.7749, -122.4194, "US"),
            ("San Jose", 37.3382, -121.8863, "US"),
            ("Palo Alto", 37.4419, -122.1430, "US"),
            ("Mountain View", 37.3861, -122.0839, "US"),
            ("Oakland", 37.8044, -122.2712, "US"),
            ("New York", 40.7128, -74.0060, "US"),
            ("Brooklyn", 40.6782, -73.9442, "US"),
            ("Los Angeles", 34.0522, -118.2437, "US"),
            ("San Diego", 32.7157, -117.1611, "US"),
            ("Seattle", 47.6062, -122.3321, "US"),
            ("Austin", 30.2672, -97.7431, "US"),
            ("Boston", 42.3601, -71.0589, "US"),
            ("Chicago", 41.8781, -87.6298, "US"),
            ("Denver", 39.7392, -104.9903, "US"),
            ("Miami", 25.7617, -80.1918, "US"),
            ("Atlanta", 33.7490, -84.3880, "US"),
            ("Washington", 38.9072, -77.0369, "US"),
            ("Portland", 45.5152, -122.6784, "US"),
            ("Dallas", 32.7767, -96.7970, "US"),
            ("Houston", 29.7604, -95.3698, "US"),
            ("Philadelphia", 39.9526, -75.1652, "US"),
            ("Phoenix", 33.4484, -112.0740, "US"),
            ("Las Vegas", 36.1699, -115.1398, "US"),
            ("Nashville", 36.1627, -86.7816, "US"),
            ("Raleigh", 35.7796, -78.6382, "US"),
            ("Minneapolis", 44.9778, -93.2650, "US"),
            ("Salt Lake City", 40.7608, -111.8910, "US"),
            ("Toronto", 43.6532, -79.3832, "CA"),
            ("Vancouver", 49.2827, -123.1207, "CA"),
            ("Montreal", 45.5017, -73.5673, "CA"),
            ("Mexico City", 19.4326, -99.1332, "MX"),
            // South America
            ("São Paulo", -23.5558, -46.6396, "BR"),
            ("Rio de Janeiro", -22.9068, -43.1729, "BR"),
            ("Buenos Aires", -34.6037, -58.3816, "AR"),
            ("Bogotá", 4.7110, -74.0721, "CO"),
            ("Santiago", -33.4489, -70.6693, "CL"),
            // Europe
            ("London", 51.5074, -0.1278, "GB"),
            ("Paris", 48.8566, 2.3522, "FR"),
            ("Berlin", 52.5200, 13.4050, "DE"),
            ("Munich", 48.1351, 11.5820, "DE"),
            ("Amsterdam", 52.3676, 4.9041, "NL"),
            ("Madrid", 40.4168, -3.7038, "ES"),
            ("Barcelona", 41.3851, 2.1734, "ES"),
            ("Lisbon", 38.7223, -9.1393, "PT"),
            ("Dublin", 53.3498, -6.2603, "IE"),
            ("Zurich", 47.3769, 8.5417, "CH"),
            ("Milan", 45.4642, 9.1900, "IT"),
            ("Rome", 41.9028, 12.4964, "IT"),
            ("Stockholm", 59.3293, 18.0686, "SE"),
            ("Copenhagen", 55.6761, 12.5683, "DK"),
            ("Oslo", 59.9139, 10.7522, "NO"),
            ("Helsinki", 60.1699, 24.9384, "FI"),
            ("Warsaw", 52.2297, 21.0122, "PL"),
            ("Vienna", 48.2082, 16.3738, "AT"),
            ("Brussels", 50.8503, 4.3517, "BE"),
            ("Prague", 50.0755, 14.4378, "CZ"),
            ("Istanbul", 41.0082, 28.9784, "TR"),
            // Middle East & Africa
            ("Dubai", 25.2048, 55.2708, "AE"),
            ("Tel Aviv", 32.0853, 34.7818, "IL"),
            ("Nairobi", -1.2921, 36.8219, "KE"),
            ("Lagos", 6.5244, 3.3792, "NG"),
            ("Cairo", 30.0444, 31.2357, "EG"),
            ("Cape Town", -33.9249, 18.4241, "ZA"),
            ("Johannesburg", -26.2041, 28.0473, "ZA"),
            // Asia & Pacific
            ("Bengaluru", 12.9716, 77.5946, "IN"),
            ("Mumbai", 19.0760, 72.8777, "IN"),
            ("Delhi", 28.7041, 77.1025, "IN"),
            ("New Delhi", 28.6139, 77.2090, "IN"),
            ("Hyderabad", 17.3850, 78.4867, "IN"),
            ("Chennai", 13.0827, 80.2707, "IN"),
            ("Pune", 18.5204, 73.8567, "IN"),
            ("Singapore", 1.3521, 103.8198, "SG"),
            ("Hong Kong", 22.3193, 114.1694, "HK"),
            ("Tokyo", 35.6762, 139.6503, "JP"),
            ("Seoul", 37.5665, 126.9780, "KR"),
            ("Shanghai", 31.2304, 121.4737, "CN"),
            ("Beijing", 39.9042, 116.4074, "CN"),
            ("Shenzhen", 22.5431, 114.0579, "CN"),
            ("Bangkok", 13.7563, 100.5018, "TH"),
            ("Jakarta", -6.2088, 106.8456, "ID"),
            ("Sydney", -33.8688, 151.2093, "AU"),
            ("Melbourne", -37.8136, 144.9631, "AU"),
            ("Auckland", -36.8485, 174.7633, "NZ"),
        ]
        var dict: [String: CityCoordinate] = [:]
        for (name, lat, lon, cc) in raw {
            dict[name.lowercased()] = CityCoordinate(
                latitude: lat,
                longitude: lon,
                resolvedName: name,
                countryCode: cc
            )
        }
        return dict
    }()
}
