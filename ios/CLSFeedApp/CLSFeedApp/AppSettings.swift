import Foundation

struct AIConfigSnapshot: Codable, Hashable {
    let provider: AIProvider
    let apiKey: String
    let apiBase: String
    let model: String
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let serverBaseURL = "app.serverBaseURL"
        static let refreshInterval = "app.refreshInterval"
        static let autoRefreshEnabled = "app.autoRefreshEnabled"
        static let offlineModeEnabled = "app.offlineModeEnabled"
        static let onboardingCompleted = "app.onboardingCompleted"
        static let keywordAlertEnabled = "app.keywordAlertEnabled"
        static let keywordSubscriptions = "app.keywordSubscriptions.items"
        static let keywordSubscriptionsLegacy = "app.keywordSubscriptions"
        static let sources = "app.sources"
        static let aiProvider = "app.aiProvider"
        static let aiApiBase = "app.aiApiBase"
        static let aiModel = "app.aiModel"
        static let aiApiKey = "app.aiApiKey"
        static let aiRetryQueueEnabled = "app.aiRetryQueueEnabled"
    }

    @Published var serverBaseURL: String {
        didSet { UserDefaults.standard.set(serverBaseURL, forKey: Keys.serverBaseURL) }
    }

    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    @Published var autoRefreshEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRefreshEnabled, forKey: Keys.autoRefreshEnabled) }
    }

    @Published var offlineModeEnabled: Bool {
        didSet { UserDefaults.standard.set(offlineModeEnabled, forKey: Keys.offlineModeEnabled) }
    }

    @Published var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    @Published var keywordAlertEnabled: Bool {
        didSet { UserDefaults.standard.set(keywordAlertEnabled, forKey: Keys.keywordAlertEnabled) }
    }

    @Published private(set) var keywordSubscriptions: [KeywordSubscription] {
        didSet { persistKeywordSubscriptions() }
    }

    @Published private(set) var selectedSourceCodes: Set<String> {
        didSet { UserDefaults.standard.set(selectedSourceCodes.joined(separator: ","), forKey: Keys.sources) }
    }

    @Published var aiProvider: AIProvider {
        didSet { UserDefaults.standard.set(aiProvider.rawValue, forKey: Keys.aiProvider) }
    }

    @Published var aiApiBase: String {
        didSet { UserDefaults.standard.set(aiApiBase, forKey: Keys.aiApiBase) }
    }

    @Published var aiModel: String {
        didSet { UserDefaults.standard.set(aiModel, forKey: Keys.aiModel) }
    }

    @Published var aiApiKey: String {
        didSet { _ = KeychainHelper.save(key: Keys.aiApiKey, value: aiApiKey) }
    }

    @Published var aiRetryQueueEnabled: Bool {
        didSet { UserDefaults.standard.set(aiRetryQueueEnabled, forKey: Keys.aiRetryQueueEnabled) }
    }

    init() {
        let defaults = UserDefaults.standard

        let defaultServer = "app://local"
        let savedServer = defaults.string(forKey: Keys.serverBaseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let server = (savedServer?.isEmpty == false) ? (savedServer ?? defaultServer) : defaultServer
        if savedServer == nil || savedServer?.isEmpty == true {
            defaults.set(defaultServer, forKey: Keys.serverBaseURL)
        }
        let interval = defaults.object(forKey: Keys.refreshInterval) as? Double ?? 8
        let autoRefreshEnabled = defaults.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? true
        let offlineModeEnabled = defaults.object(forKey: Keys.offlineModeEnabled) as? Bool ?? false
        let keywordAlertEnabled = defaults.object(forKey: Keys.keywordAlertEnabled) as? Bool ?? false

        let savedSources = defaults.string(forKey: Keys.sources) ?? ""
        let parsedSources = Set(savedSources.split(separator: ",").map { String($0) }).intersection(Set(NewsSource.allCases.map(\.rawValue)))

        let providerRaw = defaults.string(forKey: Keys.aiProvider) ?? AIProvider.deepseek.rawValue
        let provider = AIProvider(rawValue: providerRaw) ?? .deepseek

        let apiBase = defaults.string(forKey: Keys.aiApiBase) ?? provider.defaultApiBase
        let model = defaults.string(forKey: Keys.aiModel) ?? provider.defaultModel
        let apiKey = KeychainHelper.read(key: Keys.aiApiKey)
        let aiRetryQueueEnabled = defaults.object(forKey: Keys.aiRetryQueueEnabled) as? Bool ?? true
        let hasExistingSetup =
            defaults.object(forKey: Keys.serverBaseURL) != nil ||
            defaults.object(forKey: Keys.aiProvider) != nil ||
            !apiKey.isEmpty
        let onboardingCompleted = defaults.object(forKey: Keys.onboardingCompleted) as? Bool ?? hasExistingSetup

        let loadedKeywords = Self.loadKeywordSubscriptions(defaults: defaults)

        self.serverBaseURL = server
        self.refreshInterval = max(1, interval)
        self.autoRefreshEnabled = autoRefreshEnabled
        self.offlineModeEnabled = offlineModeEnabled
        self.onboardingCompleted = onboardingCompleted
        self.keywordAlertEnabled = keywordAlertEnabled
        self.keywordSubscriptions = loadedKeywords
        self.selectedSourceCodes = parsedSources.isEmpty ? Set(NewsSource.allCases.map(\.rawValue)) : parsedSources
        self.aiProvider = provider
        self.aiApiBase = apiBase
        self.aiModel = model
        self.aiApiKey = apiKey
        self.aiRetryQueueEnabled = aiRetryQueueEnabled
    }

    var selectedSources: [NewsSource] {
        NewsSource.allCases.filter { selectedSourceCodes.contains($0.rawValue) }
    }

    var effectiveServerBaseURL: String {
        if offlineModeEnabled {
            return "app://local"
        }
        return serverBaseURL
    }

    var aiSnapshot: AIConfigSnapshot {
        AIConfigSnapshot(
            provider: aiProvider,
            apiKey: aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            apiBase: aiApiBase.trimmingCharacters(in: .whitespacesAndNewlines),
            model: aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var keywordList: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in keywordSubscriptions where item.isEnabled {
            let normalized = normalizeKeyword(item.keyword)
            if normalized.isEmpty { continue }
            if seen.insert(normalized).inserted {
                out.append(normalized)
            }
        }
        return out
    }

    func addKeywordSubscription(_ raw: String) -> Bool {
        let normalized = normalizeKeyword(raw)
        guard !normalized.isEmpty else { return false }

        if let idx = keywordSubscriptions.firstIndex(where: { normalizeKeyword($0.keyword) == normalized }) {
            var changed = false
            if !keywordSubscriptions[idx].isEnabled {
                keywordSubscriptions[idx].isEnabled = true
                changed = true
            }
            let preferred = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preferred.isEmpty, keywordSubscriptions[idx].keyword != preferred {
                keywordSubscriptions[idx].keyword = preferred
                changed = true
            }
            return changed
        }

        let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        keywordSubscriptions.append(KeywordSubscription(keyword: display.isEmpty ? normalized : display))
        keywordSubscriptions.sort { $0.createdAt < $1.createdAt }
        return true
    }

    func removeKeywordSubscription(id: String) {
        keywordSubscriptions.removeAll { $0.id == id }
    }

    func setKeywordSubscriptionEnabled(_ id: String, enabled: Bool) {
        guard let idx = keywordSubscriptions.firstIndex(where: { $0.id == id }) else { return }
        keywordSubscriptions[idx].isEnabled = enabled
    }

    func updateKeywordSubscription(_ id: String, keyword: String) {
        guard let idx = keywordSubscriptions.firstIndex(where: { $0.id == id }) else { return }
        let normalized = normalizeKeyword(keyword)
        guard !normalized.isEmpty else { return }
        keywordSubscriptions[idx].keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isSourceEnabled(_ source: NewsSource) -> Bool {
        selectedSourceCodes.contains(source.rawValue)
    }

    func setSource(_ source: NewsSource, enabled: Bool) {
        var next = selectedSourceCodes
        if enabled {
            next.insert(source.rawValue)
        } else {
            next.remove(source.rawValue)
        }

        if next.isEmpty {
            next.insert(source.rawValue)
        }

        selectedSourceCodes = next
    }

    func setSources(_ sources: Set<NewsSource>) {
        let next = Set(sources.map(\.rawValue))
        if next.isEmpty { return }
        selectedSourceCodes = next
    }

    func applyProviderPreset() {
        aiApiBase = aiProvider.defaultApiBase
        aiModel = aiProvider.defaultModel
    }

    func completeOnboarding() {
        onboardingCompleted = true
    }

    func reopenOnboarding() {
        onboardingCompleted = false
    }

    private func persistKeywordSubscriptions() {
        if let data = try? JSONEncoder().encode(keywordSubscriptions) {
            UserDefaults.standard.set(data, forKey: Keys.keywordSubscriptions)
        }
    }

    private func normalizeKeyword(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadKeywordSubscriptions(defaults: UserDefaults) -> [KeywordSubscription] {
        if let data = defaults.data(forKey: Keys.keywordSubscriptions),
           let decoded = try? JSONDecoder().decode([KeywordSubscription].self, from: data),
           !decoded.isEmpty {
            return decoded
        }

        let legacy = defaults.string(forKey: Keys.keywordSubscriptionsLegacy) ?? ""
        let separators: Set<Character> = [",", "，", ";", "；", " ", "\n", "\t"]
        let migrated = legacy
            .split { separators.contains($0) }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { KeywordSubscription(keyword: $0) }

        if !migrated.isEmpty, let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Keys.keywordSubscriptions)
        }

        return migrated
    }
}
