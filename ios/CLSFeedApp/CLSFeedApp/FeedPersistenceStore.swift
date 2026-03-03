import Foundation

enum FeedUIDBucket {
    case notified
    case pinned
    case starred
    case later
    case read

    var key: String {
        switch self {
        case .notified:
            return "feed.notifiedUIDs"
        case .pinned:
            return "feed.pinnedUIDs"
        case .starred:
            return "feed.starredUIDs"
        case .later:
            return "feed.laterUIDs"
        case .read:
            return "feed.readUIDs"
        }
    }

    var defaultLimit: Int {
        switch self {
        case .notified:
            return 1200
        case .pinned, .starred, .later, .read:
            return 1800
        }
    }
}

struct FeedPersistedState {
    var notifiedUIDs: Set<String>
    var pinnedUIDs: Set<String>
    var starredUIDs: Set<String>
    var laterUIDs: Set<String>
    var readUIDs: Set<String>
    var filter: FeedFilterOption
    var latestItems: [TelegraphItem]
    var analysisByUID: [String: AIAnalysis]
    var recapByDay: [String: String]
    var lastSuccessAt: Date?
}

final class FeedPersistenceStore {
    static let shared = FeedPersistenceStore(scope: "home")

    private enum Keys: String {
        case filter = "filter"
        case latestItems = "latestItems"
        case analysisCache = "analysisCache"
        case recapCache = "recapCache"
        case lastSuccessAt = "lastSuccessAt"
    }

    private enum LegacyKeys {
        static let filter = "feed.filter"
        static let latestItems = "feed.latestItems"
        static let analysisCache = "feed.analysisCache"
        static let recapCache = "feed.recapCache"
        static let lastSuccessAt = "feed.lastSuccessAt"
    }

    private let scope: String
    private let defaults: UserDefaults

    init(scope: String = "home", defaults: UserDefaults = .standard) {
        self.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "home" : scope
        self.defaults = defaults
    }

    func loadState() -> FeedPersistedState {
        let filterRaw = defaults.string(forKey: namespaced(.filter)) ?? legacyString(for: .filter)
        let filter = FeedFilterOption(rawValue: filterRaw ?? "") ?? .all

        let items: [TelegraphItem] = decode(forKey: namespaced(.latestItems)) ?? legacyDecode(for: .latestItems) ?? []
        let analysis: [String: AIAnalysis] = decode(forKey: namespaced(.analysisCache)) ?? legacyDecode(for: .analysisCache) ?? [:]
        let recap: [String: String] = decode(forKey: namespaced(.recapCache)) ?? legacyDecode(for: .recapCache) ?? [:]

        let ts = (defaults.object(forKey: namespaced(.lastSuccessAt)) as? Double) ?? legacyTimestamp(for: .lastSuccessAt)
        let lastSuccessAt = (ts != nil && (ts ?? 0) > 0) ? Date(timeIntervalSince1970: ts ?? 0) : nil

        migrateLegacyIfNeeded(
            filter: filter,
            items: items,
            analysis: analysis,
            recap: recap,
            lastSuccessAt: ts
        )

        return FeedPersistedState(
            notifiedUIDs: loadUIDSet(.notified),
            pinnedUIDs: loadUIDSet(.pinned),
            starredUIDs: loadUIDSet(.starred),
            laterUIDs: loadUIDSet(.later),
            readUIDs: loadUIDSet(.read),
            filter: filter,
            latestItems: items,
            analysisByUID: analysis,
            recapByDay: recap,
            lastSuccessAt: lastSuccessAt
        )
    }

    func saveFilter(_ filter: FeedFilterOption) {
        defaults.set(filter.rawValue, forKey: namespaced(.filter))
    }

    @discardableResult
    func saveUIDSet(_ set: Set<String>, bucket: FeedUIDBucket, limit: Int? = nil) -> Set<String> {
        let clipped = Set(Array(set.sorted().suffix(limit ?? bucket.defaultLimit)))
        defaults.set(Array(clipped), forKey: bucket.key)
        return clipped
    }

    func saveLatestItems(_ items: [TelegraphItem], limit: Int = 260) {
        encode(Array(items.prefix(limit)), forKey: namespaced(.latestItems))
    }

    @discardableResult
    func saveAnalysisMap(_ map: [String: AIAnalysis], limit: Int = 1200) -> [String: AIAnalysis] {
        var next = map
        if next.count > limit {
            let overflow = next.count - limit
            for key in next.keys.sorted().prefix(overflow) {
                next.removeValue(forKey: key)
            }
        }
        encode(next, forKey: namespaced(.analysisCache))
        return next
    }

    @discardableResult
    func saveRecapMap(_ map: [String: String], keepDays: Int = 30) -> [String: String] {
        var sorted = map.sorted { $0.key < $1.key }
        if sorted.count > keepDays {
            sorted = Array(sorted.suffix(keepDays))
        }
        let next = Dictionary(uniqueKeysWithValues: sorted)
        encode(next, forKey: namespaced(.recapCache))
        return next
    }

    func saveLastSuccess(_ date: Date?) {
        defaults.set(date?.timeIntervalSince1970, forKey: namespaced(.lastSuccessAt))
    }

    private func namespaced(_ key: Keys) -> String {
        "feed.\(scope).\(key.rawValue)"
    }

    private func legacyString(for key: Keys) -> String? {
        guard scope == "home" else { return nil }
        switch key {
        case .filter:
            return defaults.string(forKey: LegacyKeys.filter)
        default:
            return nil
        }
    }

    private func legacyTimestamp(for key: Keys) -> Double? {
        guard scope == "home" else { return nil }
        switch key {
        case .lastSuccessAt:
            return defaults.object(forKey: LegacyKeys.lastSuccessAt) as? Double
        default:
            return nil
        }
    }

    private func legacyDecode<T: Decodable>(for key: Keys) -> T? {
        guard scope == "home" else { return nil }
        let legacyKey: String
        switch key {
        case .latestItems:
            legacyKey = LegacyKeys.latestItems
        case .analysisCache:
            legacyKey = LegacyKeys.analysisCache
        case .recapCache:
            legacyKey = LegacyKeys.recapCache
        default:
            return nil
        }
        return decode(forKey: legacyKey)
    }

    private func migrateLegacyIfNeeded(
        filter: FeedFilterOption,
        items: [TelegraphItem],
        analysis: [String: AIAnalysis],
        recap: [String: String],
        lastSuccessAt: Double?
    ) {
        guard scope == "home" else { return }

        if defaults.object(forKey: namespaced(.filter)) == nil {
            defaults.set(filter.rawValue, forKey: namespaced(.filter))
        }
        if defaults.object(forKey: namespaced(.latestItems)) == nil, !items.isEmpty {
            encode(items, forKey: namespaced(.latestItems))
        }
        if defaults.object(forKey: namespaced(.analysisCache)) == nil, !analysis.isEmpty {
            encode(analysis, forKey: namespaced(.analysisCache))
        }
        if defaults.object(forKey: namespaced(.recapCache)) == nil, !recap.isEmpty {
            encode(recap, forKey: namespaced(.recapCache))
        }
        if defaults.object(forKey: namespaced(.lastSuccessAt)) == nil, let ts = lastSuccessAt, ts > 0 {
            defaults.set(ts, forKey: namespaced(.lastSuccessAt))
        }
    }

    private func loadUIDSet(_ bucket: FeedUIDBucket) -> Set<String> {
        Set(defaults.array(forKey: bucket.key) as? [String] ?? [])
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private func decode<T: Decodable>(forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
