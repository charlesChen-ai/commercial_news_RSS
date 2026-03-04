import Foundation
#if os(iOS)
import UIKit
#endif

extension Notification.Name {
    static let cloudStateDidApply = Notification.Name("app.cloudStateDidApply")
    static let pushFeedbackActionReceived = Notification.Name("app.pushFeedbackActionReceived")
    static let appTelemetryDidUpdate = Notification.Name("app.telemetryDidUpdate")
    static let feedSnapshotDidUpdate = Notification.Name("app.feedSnapshotDidUpdate")
}

enum PushFeedbackActionID {
    static let tooFrequent = "push.feedback.tooFrequent"
    static let notInterested = "push.feedback.notInterested"
}

#if os(iOS)
enum AppHaptics {
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func impact() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.86)
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }
}
#else
enum AppHaptics {
    static func selection() {}
    static func impact() {}
    static func success() {}
    static func warning() {}
}
#endif

struct AIConfigSnapshot: Codable, Hashable {
    let provider: AIProvider
    let apiKey: String
    let apiBase: String
    let model: String
}

struct AppBackgroundSettingsSnapshot: Hashable {
    let serverBaseURL: String
    let offlineModeEnabled: Bool
    let keywordAlertEnabled: Bool
    let keywordList: [String]
    let selectedSources: [NewsSource]
    let pushStrategy: PushStrategySnapshot
    let autoRefreshEnabled: Bool
    let refreshInterval: Double

    var effectiveServerBaseURL: String {
        offlineModeEnabled ? "app://local" : serverBaseURL
    }
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
        static let pushDeliveryMode = "app.push.deliveryMode"
        static let pushTradingHoursOnly = "app.push.tradingHoursOnly"
        static let pushDndEnabled = "app.push.dndEnabled"
        static let pushDndStart = "app.push.dndStart"
        static let pushDndEnd = "app.push.dndEnd"
        static let pushRateLimitPerHour = "app.push.rateLimitPerHour"
        static let pushSources = "app.push.sources"
        static let sourceMuteUntilByCode = "app.sources.muteUntilByCode"
        static let feedCollapseThreshold = "app.feed.quality.collapseThreshold"
        static let feedSourcePriorityByCode = "app.feed.quality.sourcePriorityByCode"
        static let feedUncollapseUIDUntilByUID = "app.feed.quality.uncollapseUIDUntilByUID"
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

    @Published var pushDeliveryMode: PushDeliveryMode {
        didSet { UserDefaults.standard.set(pushDeliveryMode.rawValue, forKey: Keys.pushDeliveryMode) }
    }

    @Published var pushTradingHoursOnly: Bool {
        didSet { UserDefaults.standard.set(pushTradingHoursOnly, forKey: Keys.pushTradingHoursOnly) }
    }

    @Published var pushDoNotDisturbEnabled: Bool {
        didSet { UserDefaults.standard.set(pushDoNotDisturbEnabled, forKey: Keys.pushDndEnabled) }
    }

    @Published var pushDoNotDisturbStart: String {
        didSet { UserDefaults.standard.set(pushDoNotDisturbStart, forKey: Keys.pushDndStart) }
    }

    @Published var pushDoNotDisturbEnd: String {
        didSet { UserDefaults.standard.set(pushDoNotDisturbEnd, forKey: Keys.pushDndEnd) }
    }

    @Published var pushRateLimitPerHour: Double {
        didSet { UserDefaults.standard.set(pushRateLimitPerHour, forKey: Keys.pushRateLimitPerHour) }
    }

    @Published private(set) var pushSourceCodes: Set<String> {
        didSet { UserDefaults.standard.set(pushSourceCodes.joined(separator: ","), forKey: Keys.pushSources) }
    }

    @Published private(set) var sourceMuteUntilByCode: [String: Double] {
        didSet { persistSourceMutes() }
    }

    @Published var feedCollapseThreshold: Double {
        didSet { UserDefaults.standard.set(feedCollapseThreshold, forKey: Keys.feedCollapseThreshold) }
    }

    @Published private(set) var feedSourcePriorityByCode: [String: Int] {
        didSet { persistFeedSourcePriorities() }
    }

    @Published private(set) var feedUncollapseUIDUntilByUID: [String: Double] {
        didSet { persistFeedUncollapseUIDs() }
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
        let pushDeliveryModeRaw = defaults.string(forKey: Keys.pushDeliveryMode) ?? PushStrategySnapshot.default.deliveryMode.rawValue
        let pushDeliveryMode = PushDeliveryMode(rawValue: pushDeliveryModeRaw) ?? .all
        let pushTradingHoursOnly = defaults.object(forKey: Keys.pushTradingHoursOnly) as? Bool ?? PushStrategySnapshot.default.tradingHoursOnly
        let pushDndEnabled = defaults.object(forKey: Keys.pushDndEnabled) as? Bool ?? PushStrategySnapshot.default.doNotDisturbEnabled
        let pushDndStart = defaults.string(forKey: Keys.pushDndStart) ?? PushStrategySnapshot.default.doNotDisturbStart
        let pushDndEnd = defaults.string(forKey: Keys.pushDndEnd) ?? PushStrategySnapshot.default.doNotDisturbEnd
        let pushRateLimitPerHour = defaults.object(forKey: Keys.pushRateLimitPerHour) as? Double ?? Double(PushStrategySnapshot.default.rateLimitPerHour)
        let savedPushSources = defaults.string(forKey: Keys.pushSources) ?? ""
        let parsedPushSources = Set(savedPushSources.split(separator: ",").map { String($0) }).intersection(Set(NewsSource.allCases.map(\.rawValue)))
        let loadedMuteMap = Self.prunedSourceMuteMap(Self.loadSourceMutes(defaults: defaults), now: Date().timeIntervalSince1970)
        let feedCollapseThreshold = defaults.object(forKey: Keys.feedCollapseThreshold) as? Double ?? Double(FeedQualitySnapshot.default.collapseThreshold)
        let feedSourcePriorityByCode = Self.prunedSourcePriorityMap(Self.loadSourcePriorities(defaults: defaults))
        let feedUncollapseUIDUntilByUID = Self.prunedFeedUncollapseMap(
            Self.loadFeedUncollapseMap(defaults: defaults),
            now: Date().timeIntervalSince1970
        )
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
        self.pushDeliveryMode = pushDeliveryMode
        self.pushTradingHoursOnly = pushTradingHoursOnly
        self.pushDoNotDisturbEnabled = pushDndEnabled
        self.pushDoNotDisturbStart = pushDndStart
        self.pushDoNotDisturbEnd = pushDndEnd
        self.pushRateLimitPerHour = max(1, min(30, pushRateLimitPerHour))
        self.pushSourceCodes = parsedPushSources.isEmpty ? Set(NewsSource.allCases.map(\.rawValue)) : parsedPushSources
        self.sourceMuteUntilByCode = loadedMuteMap
        self.feedCollapseThreshold = max(55, min(90, feedCollapseThreshold))
        self.feedSourcePriorityByCode = feedSourcePriorityByCode
        self.feedUncollapseUIDUntilByUID = feedUncollapseUIDUntilByUID
    }

    var selectedSources: [NewsSource] {
        let active = NewsSource.allCases.filter { selectedSourceCodes.contains($0.rawValue) }
        let now = Date().timeIntervalSince1970
        return active.filter { (sourceMuteUntilByCode[$0.rawValue] ?? 0) <= now }
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

    var pushStrategy: PushStrategySnapshot {
        PushStrategySnapshot(
            deliveryMode: pushDeliveryMode,
            tradingHoursOnly: pushTradingHoursOnly,
            doNotDisturbEnabled: pushDoNotDisturbEnabled,
            doNotDisturbStart: normalizeClockText(pushDoNotDisturbStart, fallback: "22:30"),
            doNotDisturbEnd: normalizeClockText(pushDoNotDisturbEnd, fallback: "07:30"),
            rateLimitPerHour: Int(max(1, min(30, pushRateLimitPerHour.rounded()))),
            sourceCodes: Array(pushSourceCodes).sorted()
        )
    }

    var feedQualitySnapshot: FeedQualitySnapshot {
        let sanitized = Self.prunedFeedUncollapseMap(
            feedUncollapseUIDUntilByUID,
            now: Date().timeIntervalSince1970
        )
        return FeedQualitySnapshot(
            collapseThreshold: Int(max(55, min(90, feedCollapseThreshold.rounded()))),
            sourcePriorityByCode: Self.prunedSourcePriorityMap(feedSourcePriorityByCode),
            uncollapseUIDs: Set(sanitized.keys)
        )
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

    func sourcePriorityWeight(_ source: NewsSource) -> Int {
        feedQualitySnapshot.priority(for: source.rawValue)
    }

    func setSourcePriority(_ source: NewsSource, weight: Int) {
        let clamped = max(-3, min(3, weight))
        var next = feedSourcePriorityByCode
        if clamped == 0 {
            next.removeValue(forKey: source.rawValue)
        } else {
            next[source.rawValue] = clamped
        }
        feedSourcePriorityByCode = Self.prunedSourcePriorityMap(next)
    }

    func resetSourcePriorityWeights() {
        feedSourcePriorityByCode = [:]
    }

    func isUncollapseEnabled(uid: String, now: Date = Date()) -> Bool {
        let normalized = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let ts = feedUncollapseUIDUntilByUID[normalized] ?? 0
        return ts > now.timeIntervalSince1970
    }

    func setUncollapse(uid: String, duration: TimeInterval = 24 * 3600) {
        let normalized = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard duration > 0 else { return }

        let now = Date().timeIntervalSince1970
        let deadline = now + duration
        var next = Self.prunedFeedUncollapseMap(feedUncollapseUIDUntilByUID, now: now)
        next[normalized] = max(next[normalized] ?? 0, deadline)
        feedUncollapseUIDUntilByUID = next
    }

    func clearUncollapse(uid: String) {
        let normalized = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard feedUncollapseUIDUntilByUID[normalized] != nil else { return }
        var next = feedUncollapseUIDUntilByUID
        next.removeValue(forKey: normalized)
        feedUncollapseUIDUntilByUID = Self.prunedFeedUncollapseMap(next, now: Date().timeIntervalSince1970)
    }

    func resetUncollapseUIDs() {
        feedUncollapseUIDUntilByUID = [:]
    }

    func isSourceTemporarilyMuted(_ source: NewsSource, now: Date = Date()) -> Bool {
        (sourceMuteUntilByCode[source.rawValue] ?? 0) > now.timeIntervalSince1970
    }

    func sourceMuteRemainingText(_ source: NewsSource, now: Date = Date()) -> String? {
        let nowTs = now.timeIntervalSince1970
        guard let until = sourceMuteUntilByCode[source.rawValue], until > nowTs else { return nil }
        let left = Int((until - nowTs).rounded())
        if left <= 0 { return nil }
        if left >= 24 * 3600 {
            let days = Int(ceil(Double(left) / Double(24 * 3600)))
            return "静音中 \(days) 天"
        }
        let hours = Int(ceil(Double(left) / 3600.0))
        return "静音中 \(max(1, hours)) 小时"
    }

    func muteSource(_ source: NewsSource, duration: TimeInterval) {
        guard duration > 0 else { return }
        let deadline = Date().timeIntervalSince1970 + duration
        var next = sourceMuteUntilByCode
        next[source.rawValue] = max(next[source.rawValue] ?? 0, deadline)
        sourceMuteUntilByCode = Self.prunedSourceMuteMap(next, now: Date().timeIntervalSince1970)
    }

    func unmuteSource(_ source: NewsSource) {
        guard sourceMuteUntilByCode[source.rawValue] != nil else { return }
        var next = sourceMuteUntilByCode
        next.removeValue(forKey: source.rawValue)
        sourceMuteUntilByCode = Self.prunedSourceMuteMap(next, now: Date().timeIntervalSince1970)
    }

    func applyPushFeedbackAction(_ actionID: String, sourceRaw: String?) {
        switch actionID {
        case PushFeedbackActionID.tooFrequent:
            pushRateLimitPerHour = max(1, pushRateLimitPerHour - 2)
            AppHaptics.warning()
        case PushFeedbackActionID.notInterested:
            if let raw = sourceRaw,
               let source = NewsSource(rawValue: raw) {
                muteSource(source, duration: 24 * 3600)
            }
            AppHaptics.warning()
        default:
            break
        }
    }

    func isPushSourceEnabled(_ source: NewsSource) -> Bool {
        pushSourceCodes.contains(source.rawValue)
    }

    func setPushSource(_ source: NewsSource, enabled: Bool) {
        var next = pushSourceCodes
        if enabled {
            next.insert(source.rawValue)
        } else {
            next.remove(source.rawValue)
        }
        if next.isEmpty {
            next.insert(source.rawValue)
        }
        pushSourceCodes = next
    }

    func applyPushStrategy(_ snapshot: PushStrategySnapshot) {
        pushDeliveryMode = snapshot.deliveryMode
        pushTradingHoursOnly = snapshot.tradingHoursOnly
        pushDoNotDisturbEnabled = snapshot.doNotDisturbEnabled
        pushDoNotDisturbStart = normalizeClockText(snapshot.doNotDisturbStart, fallback: "22:30")
        pushDoNotDisturbEnd = normalizeClockText(snapshot.doNotDisturbEnd, fallback: "07:30")
        pushRateLimitPerHour = Double(max(1, min(30, snapshot.rateLimitPerHour)))
        let allowed = Set(snapshot.sourceCodes).intersection(Set(NewsSource.allCases.map(\.rawValue)))
        pushSourceCodes = allowed.isEmpty ? Set(NewsSource.allCases.map(\.rawValue)) : allowed
    }

    func replaceKeywordSubscriptions(_ list: [KeywordSubscription]) {
        var seen = Set<String>()
        var normalized: [KeywordSubscription] = []
        normalized.reserveCapacity(list.count)

        for item in list {
            let keyword = item.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeKeyword(keyword)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            normalized.append(
                KeywordSubscription(
                    id: item.id,
                    keyword: keyword,
                    isEnabled: item.isEnabled,
                    createdAt: item.createdAt
                )
            )
            if normalized.count >= 500 { break }
        }
        keywordSubscriptions = normalized.sorted { $0.createdAt < $1.createdAt }
    }

    func buildCloudState() -> AccountCloudState {
        let feed = FeedPersistenceStore(scope: "home").exportCloudState()
        return AccountCloudState(
            starredUIDs: feed.starredUIDs,
            readUIDs: feed.readUIDs,
            keywordSubscriptions: keywordSubscriptions,
            selectedSources: Array(selectedSourceCodes).sorted(),
            pushStrategy: pushStrategy,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func applyCloudState(_ cloud: AccountCloudState) {
        FeedPersistenceStore(scope: "home").applyCloudState(
            starredUIDs: cloud.starredUIDs,
            readUIDs: cloud.readUIDs
        )
        replaceKeywordSubscriptions(cloud.keywordSubscriptions)
        let nextSources = Set(cloud.selectedSources).intersection(Set(NewsSource.allCases.map(\.rawValue)))
        if !nextSources.isEmpty {
            selectedSourceCodes = nextSources
        }
        applyPushStrategy(cloud.pushStrategy)
        NotificationCenter.default.post(name: .cloudStateDidApply, object: nil)
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

    nonisolated static func backgroundSnapshot(defaults: UserDefaults = .standard) -> AppBackgroundSettingsSnapshot {
        let defaultServer = "app://local"
        let savedServer = defaults.string(forKey: Keys.serverBaseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let server = (savedServer?.isEmpty == false) ? (savedServer ?? defaultServer) : defaultServer
        let offlineModeEnabled = defaults.object(forKey: Keys.offlineModeEnabled) as? Bool ?? false
        let keywordAlertEnabled = defaults.object(forKey: Keys.keywordAlertEnabled) as? Bool ?? false
        let autoRefreshEnabled = defaults.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? true
        let refreshInterval = max(1, defaults.object(forKey: Keys.refreshInterval) as? Double ?? 8)

        let savedSources = defaults.string(forKey: Keys.sources) ?? ""
        let parsedSources = Set(savedSources.split(separator: ",").map { String($0) })
            .intersection(Set(NewsSource.allCases.map(\.rawValue)))
        let baseSelectedSources = parsedSources.isEmpty
            ? Array(NewsSource.allCases)
            : NewsSource.allCases.filter { parsedSources.contains($0.rawValue) }
        let muteMap = prunedSourceMuteMap(loadSourceMutes(defaults: defaults), now: Date().timeIntervalSince1970)
        let selectedSources = baseSelectedSources.filter { (muteMap[$0.rawValue] ?? 0) <= Date().timeIntervalSince1970 }

        let keywordList = loadKeywordSubscriptions(defaults: defaults)
            .filter(\.isEnabled)
            .map { $0.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let pushModeRaw = defaults.string(forKey: Keys.pushDeliveryMode) ?? PushStrategySnapshot.default.deliveryMode.rawValue
        let pushMode = PushDeliveryMode(rawValue: pushModeRaw) ?? .all
        let pushTradingHoursOnly = defaults.object(forKey: Keys.pushTradingHoursOnly) as? Bool ?? PushStrategySnapshot.default.tradingHoursOnly
        let pushDndEnabled = defaults.object(forKey: Keys.pushDndEnabled) as? Bool ?? PushStrategySnapshot.default.doNotDisturbEnabled
        let pushDndStart = defaults.string(forKey: Keys.pushDndStart) ?? PushStrategySnapshot.default.doNotDisturbStart
        let pushDndEnd = defaults.string(forKey: Keys.pushDndEnd) ?? PushStrategySnapshot.default.doNotDisturbEnd
        let pushRateLimitPerHour = Int(max(1, min(30, defaults.object(forKey: Keys.pushRateLimitPerHour) as? Double ?? Double(PushStrategySnapshot.default.rateLimitPerHour))))
        let savedPushSources = defaults.string(forKey: Keys.pushSources) ?? ""
        let parsedPushSources = Set(savedPushSources.split(separator: ",").map { String($0) })
            .intersection(Set(NewsSource.allCases.map(\.rawValue)))
        let pushSources = parsedPushSources.isEmpty ? NewsSource.allCases.map(\.rawValue) : Array(parsedPushSources).sorted()

        return AppBackgroundSettingsSnapshot(
            serverBaseURL: server,
            offlineModeEnabled: offlineModeEnabled,
            keywordAlertEnabled: keywordAlertEnabled,
            keywordList: keywordList,
            selectedSources: selectedSources,
            pushStrategy: PushStrategySnapshot(
                deliveryMode: pushMode,
                tradingHoursOnly: pushTradingHoursOnly,
                doNotDisturbEnabled: pushDndEnabled,
                doNotDisturbStart: normalizeClockText(pushDndStart, fallback: "22:30"),
                doNotDisturbEnd: normalizeClockText(pushDndEnd, fallback: "07:30"),
                rateLimitPerHour: pushRateLimitPerHour,
                sourceCodes: pushSources
            ),
            autoRefreshEnabled: autoRefreshEnabled,
            refreshInterval: refreshInterval
        )
    }

    nonisolated static func feedQualitySnapshot(defaults: UserDefaults = .standard) -> FeedQualitySnapshot {
        let thresholdRaw = defaults.object(forKey: Keys.feedCollapseThreshold) as? Double ?? Double(FeedQualitySnapshot.default.collapseThreshold)
        let threshold = Int(max(55, min(90, thresholdRaw.rounded())))
        let priorities = prunedSourcePriorityMap(loadSourcePriorities(defaults: defaults))
        let uncollapse = prunedFeedUncollapseMap(loadFeedUncollapseMap(defaults: defaults), now: Date().timeIntervalSince1970)
        return FeedQualitySnapshot(
            collapseThreshold: threshold,
            sourcePriorityByCode: priorities,
            uncollapseUIDs: Set(uncollapse.keys)
        )
    }

    private func persistKeywordSubscriptions() {
        if let data = try? JSONEncoder().encode(keywordSubscriptions) {
            UserDefaults.standard.set(data, forKey: Keys.keywordSubscriptions)
        }
    }

    private func persistSourceMutes() {
        let sanitized = Self.prunedSourceMuteMap(sourceMuteUntilByCode, now: Date().timeIntervalSince1970)
        if sanitized != sourceMuteUntilByCode {
            sourceMuteUntilByCode = sanitized
            return
        }
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: Keys.sourceMuteUntilByCode)
        }
    }

    private func persistFeedSourcePriorities() {
        let sanitized = Self.prunedSourcePriorityMap(feedSourcePriorityByCode)
        if sanitized != feedSourcePriorityByCode {
            feedSourcePriorityByCode = sanitized
            return
        }
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: Keys.feedSourcePriorityByCode)
        }
    }

    private func persistFeedUncollapseUIDs() {
        let sanitized = Self.prunedFeedUncollapseMap(
            feedUncollapseUIDUntilByUID,
            now: Date().timeIntervalSince1970
        )
        if sanitized != feedUncollapseUIDUntilByUID {
            feedUncollapseUIDUntilByUID = sanitized
            return
        }
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: Keys.feedUncollapseUIDUntilByUID)
        }
    }

    private func normalizeKeyword(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private nonisolated static func normalizeClockText(_ raw: String, fallback: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fallback }
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              (0...23).contains(hh),
              (0...59).contains(mm) else {
            return fallback
        }
        return String(format: "%02d:%02d", hh, mm)
    }

    private func normalizeClockText(_ raw: String, fallback: String) -> String {
        Self.normalizeClockText(raw, fallback: fallback)
    }

    private nonisolated static func loadKeywordSubscriptions(defaults: UserDefaults) -> [KeywordSubscription] {
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

    private nonisolated static func loadSourceMutes(defaults: UserDefaults) -> [String: Double] {
        guard let data = defaults.data(forKey: Keys.sourceMuteUntilByCode),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func loadSourcePriorities(defaults: UserDefaults) -> [String: Int] {
        guard let data = defaults.data(forKey: Keys.feedSourcePriorityByCode),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func loadFeedUncollapseMap(defaults: UserDefaults) -> [String: Double] {
        guard let data = defaults.data(forKey: Keys.feedUncollapseUIDUntilByUID),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func prunedSourceMuteMap(_ raw: [String: Double], now: Double) -> [String: Double] {
        let allowed = Set(NewsSource.allCases.map(\.rawValue))
        var out: [String: Double] = [:]
        out.reserveCapacity(raw.count)
        for (code, until) in raw {
            if until <= now { continue }
            if !allowed.contains(code) { continue }
            out[code] = until
        }
        return out
    }

    private nonisolated static func prunedSourcePriorityMap(_ raw: [String: Int]) -> [String: Int] {
        let allowed = Set(NewsSource.allCases.map(\.rawValue))
        var out: [String: Int] = [:]
        out.reserveCapacity(raw.count)
        for (code, value) in raw {
            guard allowed.contains(code) else { continue }
            let clamped = max(-3, min(3, value))
            if clamped == 0 { continue }
            out[code] = clamped
        }
        return out
    }

    private nonisolated static func prunedFeedUncollapseMap(_ raw: [String: Double], now: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        out.reserveCapacity(raw.count)
        for (uid, until) in raw {
            let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard until > now else { continue }
            out[trimmed] = until
        }
        return out
    }
}

@MainActor
final class AccountSessionStore: ObservableObject {
    private enum Keys {
        static let accountId = "account.id"
        static let provider = "account.provider"
        static let phoneMasked = "account.phoneMasked"
        static let appleMasked = "account.appleMasked"
        static let expiresAt = "account.expiresAt"
        static let deviceId = "account.deviceId"
        static let lastSyncAt = "account.lastSyncAt"
        static let lastSyncMessage = "account.lastSyncMessage"
        static let lastSyncError = "account.lastSyncError"
    }

    private enum KeychainKeys {
        static let authToken = "account.authToken"
    }

    @Published private(set) var session: AccountSessionInfo?
    @Published var authError: String?
    @Published var syncMessage: String
    @Published var lastSyncError: String
    @Published var isSyncing = false
    @Published var lastSyncAt: Date?

    private var autoSyncTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        let token = KeychainHelper.read(key: KeychainKeys.authToken).trimmingCharacters(in: .whitespacesAndNewlines)
        let accountId = defaults.string(forKey: Keys.accountId) ?? ""
        let provider = defaults.string(forKey: Keys.provider) ?? ""
        let phoneMasked = defaults.string(forKey: Keys.phoneMasked)
        let appleMasked = defaults.string(forKey: Keys.appleMasked)
        let expiresAt = defaults.string(forKey: Keys.expiresAt) ?? ""
        if !token.isEmpty, !accountId.isEmpty, !provider.isEmpty {
            session = AccountSessionInfo(
                token: token,
                account: AccountProfile(
                    accountId: accountId,
                    provider: provider,
                    phoneMasked: phoneMasked,
                    appleMasked: appleMasked,
                    createdAt: ""
                ),
                expiresAt: expiresAt
            )
        }

        let ts = defaults.object(forKey: Keys.lastSyncAt) as? Double
        lastSyncAt = (ts != nil && (ts ?? 0) > 0) ? Date(timeIntervalSince1970: ts ?? 0) : nil
        syncMessage = defaults.string(forKey: Keys.lastSyncMessage) ?? ""
        lastSyncError = defaults.string(forKey: Keys.lastSyncError) ?? ""
    }

    var isLoggedIn: Bool { session != nil }

    var accountTitle: String {
        guard let session else { return "未登录" }
        let masked = session.account.phoneMasked ?? session.account.appleMasked ?? session.account.accountId
        return "\(session.account.provider.uppercased()) · \(masked)"
    }

    var token: String {
        session?.token ?? ""
    }

    var syncStatusText: String {
        if isSyncing {
            return "同步中"
        }
        if !lastSyncError.isEmpty {
            return "同步失败"
        }
        if lastSyncAt != nil {
            return "已同步"
        }
        return "未同步"
    }

    func requestPhoneCode(baseURL: String, phone: String) async -> String? {
        let normalized = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            authError = "请输入手机号"
            return nil
        }

        do {
            let response = try await APIClient.shared.requestPhoneCode(baseURL: baseURL, phone: normalized)
            authError = nil
            return response.debugCode
        } catch {
            authError = error.localizedDescription
            return nil
        }
    }

    func verifyPhoneCode(using settings: AppSettings, phone: String, code: String) async {
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPhone.isEmpty else {
            authError = "请输入手机号"
            return
        }
        guard !normalizedCode.isEmpty else {
            authError = "请输入验证码"
            return
        }

        do {
            let session = try await APIClient.shared.verifyPhoneCode(
                baseURL: settings.effectiveServerBaseURL,
                phone: normalizedPhone,
                code: normalizedCode,
                deviceID: Self.deviceID(),
                deviceName: Self.deviceName()
            )
            persistSession(session)
            authError = nil
            await restoreFromCloud(using: settings)
            startAutoSync(using: settings)
        } catch {
            authError = error.localizedDescription
        }
    }

    func loginWithApple(using settings: AppSettings, appleUserID: String, email: String?, fullName: String?) async {
        let userID = appleUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty else {
            authError = "Apple 登录凭证无效"
            return
        }

        do {
            let session = try await APIClient.shared.loginWithApple(
                baseURL: settings.effectiveServerBaseURL,
                appleUserID: userID,
                email: email,
                fullName: fullName,
                deviceID: Self.deviceID(),
                deviceName: Self.deviceName()
            )
            persistSession(session)
            authError = nil
            await restoreFromCloud(using: settings)
            startAutoSync(using: settings)
        } catch {
            authError = error.localizedDescription
        }
    }

    func logout(using settings: AppSettings) async {
        if let session {
            try? await APIClient.shared.logout(baseURL: settings.effectiveServerBaseURL, token: session.token)
        }
        clearSession()
    }

    func restoreFromCloud(using settings: AppSettings) async {
        guard let session else { return }
        guard !settings.effectiveServerBaseURL.hasPrefix("app://local") else { return }
        isSyncing = true
        syncMessage = "正在从云端恢复..."
        lastSyncError = ""
        defer { isSyncing = false }

        do {
            let cloud = try await APIClient.shared.pullCloudState(
                baseURL: settings.effectiveServerBaseURL,
                token: session.token
            )
            settings.applyCloudState(cloud)
            syncMessage = "已从云端恢复"
            lastSyncError = ""
            markSyncSuccess(emitHaptic: false)
        } catch {
            let message = error.localizedDescription
            syncMessage = "云端恢复失败：\(message)"
            lastSyncError = message
            authError = message
            persistSyncStatus()
        }
    }

    func syncNow(using settings: AppSettings, reason: String = "manual") async {
        guard let session else { return }
        guard !settings.effectiveServerBaseURL.hasPrefix("app://local") else { return }
        guard !isSyncing else { return }
        isSyncing = true
        syncMessage = "同步中..."
        lastSyncError = ""
        defer { isSyncing = false }

        do {
            let local = settings.buildCloudState()
            _ = try await APIClient.shared.pushCloudState(
                baseURL: settings.effectiveServerBaseURL,
                token: session.token,
                state: local
            )
            let remote = try await APIClient.shared.pullCloudState(
                baseURL: settings.effectiveServerBaseURL,
                token: session.token
            )
            settings.applyCloudState(remote)
            syncMessage = "云同步成功（\(reason)）"
            lastSyncError = ""
            markSyncSuccess(emitHaptic: reason != "auto")
        } catch {
            let message = error.localizedDescription
            syncMessage = "云同步失败：\(message)"
            lastSyncError = message
            authError = message
            persistSyncStatus()
        }
    }

    func startAutoSync(using settings: AppSettings) {
        stopAutoSync()
        guard session != nil else { return }

        autoSyncTask = Task {
            while !Task.isCancelled {
                await syncNow(using: settings, reason: "auto")
                try? await Task.sleep(nanoseconds: 55_000_000_000)
            }
        }
    }

    func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    private func persistSession(_ session: AccountSessionInfo, defaults: UserDefaults = .standard) {
        self.session = session
        _ = KeychainHelper.save(key: KeychainKeys.authToken, value: session.token)
        defaults.set(session.account.accountId, forKey: Keys.accountId)
        defaults.set(session.account.provider, forKey: Keys.provider)
        defaults.set(session.account.phoneMasked, forKey: Keys.phoneMasked)
        defaults.set(session.account.appleMasked, forKey: Keys.appleMasked)
        defaults.set(session.expiresAt, forKey: Keys.expiresAt)
    }

    private func clearSession(defaults: UserDefaults = .standard) {
        session = nil
        _ = KeychainHelper.delete(key: KeychainKeys.authToken)
        defaults.removeObject(forKey: Keys.accountId)
        defaults.removeObject(forKey: Keys.provider)
        defaults.removeObject(forKey: Keys.phoneMasked)
        defaults.removeObject(forKey: Keys.appleMasked)
        defaults.removeObject(forKey: Keys.expiresAt)
        defaults.removeObject(forKey: Keys.lastSyncAt)
        defaults.removeObject(forKey: Keys.lastSyncMessage)
        defaults.removeObject(forKey: Keys.lastSyncError)
        lastSyncAt = nil
        syncMessage = ""
        lastSyncError = ""
        authError = nil
        stopAutoSync()
    }

    private func markSyncSuccess(defaults: UserDefaults = .standard, emitHaptic: Bool = false) {
        lastSyncAt = Date()
        lastSyncError = ""
        persistSyncStatus(defaults: defaults)
        if emitHaptic {
            AppHaptics.success()
        }
    }

    private func persistSyncStatus(defaults: UserDefaults = .standard) {
        defaults.set(lastSyncAt?.timeIntervalSince1970, forKey: Keys.lastSyncAt)
        defaults.set(syncMessage, forKey: Keys.lastSyncMessage)
        defaults.set(lastSyncError, forKey: Keys.lastSyncError)
    }

    private static func deviceID(defaults: UserDefaults = .standard) -> String {
        let existing = defaults.string(forKey: Keys.deviceId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: Keys.deviceId)
        return value
    }

    private static func deviceName() -> String {
#if os(iOS)
        UIDevice.current.name
#elseif os(macOS)
        Host.current().localizedName ?? "macOS"
#else
        "device"
#endif
    }
}
