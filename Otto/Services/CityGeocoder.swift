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

    /// Resolve one city. `key` is the normalized (folded) key (also the cache
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

    /// Instant, offline coordinates for every city in the shared canonical
    /// table (`CanonicalCities`). Keyed by the normalizer's folded key so seed
    /// lookups line up with the grouping keys. Any city not seeded falls back
    /// to a throttled `CLGeocoder` lookup, then gets cached.
    static let seed: [String: CityCoordinate] = {
        var dict: [String: CityCoordinate] = [:]
        for c in CanonicalCities.all {
            dict[LocationNormalizer.fold(c.name)] = CityCoordinate(
                latitude: c.latitude,
                longitude: c.longitude,
                resolvedName: c.name,
                countryCode: c.countryCode
            )
        }
        return dict
    }()
}
