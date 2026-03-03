import Foundation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var items: [TelegraphItem] = []
    @Published var clusters: [TelegraphCluster] = []
    @Published var sourceHealth: [SourceHealth] = []
    @Published var lastError: String?
    @Published var isLoading = false
    @Published var analyzingUIDs: Set<String> = []
    @Published var analysisByUID: [String: AIAnalysis] = [:]
    @Published var quoteByCode: [String: StockQuote] = [:]
    @Published var filter: FeedFilterOption = .all
    @Published var latestRecapText: String = ""

    private let notifiedUIDStoreKey = "feed.notifiedUIDs"
    private let pinnedStoreKey = "feed.pinnedUIDs"
    private let starredStoreKey = "feed.starredUIDs"
    private let laterStoreKey = "feed.laterUIDs"
    private let readStoreKey = "feed.readUIDs"
    private let filterStoreKey = "feed.filter"
    private let latestItemsStoreKey = "feed.latestItems"
    private let analysisCacheStoreKey = "feed.analysisCache"
    private let recapCacheStoreKey = "feed.recapCache"

    private var notifiedUIDs: Set<String>
    private var pinnedUIDs: Set<String>
    private var starredUIDs: Set<String>
    private var laterUIDs: Set<String>
    private var readUIDs: Set<String>
    private var recapByDay: [String: String]
    private var hasLoadedSnapshot = false
    private var autoRefreshTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        notifiedUIDs = Set(defaults.array(forKey: notifiedUIDStoreKey) as? [String] ?? [])
        pinnedUIDs = Set(defaults.array(forKey: pinnedStoreKey) as? [String] ?? [])
        starredUIDs = Set(defaults.array(forKey: starredStoreKey) as? [String] ?? [])
        laterUIDs = Set(defaults.array(forKey: laterStoreKey) as? [String] ?? [])
        readUIDs = Set(defaults.array(forKey: readStoreKey) as? [String] ?? [])
        recapByDay = Self.loadRecapCache(key: recapCacheStoreKey)

        if let raw = defaults.string(forKey: filterStoreKey), let f = FeedFilterOption(rawValue: raw) {
            filter = f
        }

        analysisByUID = Self.loadAnalysisCache(key: analysisCacheStoreKey)

        let cachedItems = Self.loadCachedItems(key: latestItemsStoreKey)
        if !cachedItems.isEmpty {
            items = cachedItems
            clusters = buildClusters(from: cachedItems)
            hasLoadedSnapshot = true
        }
    }

    var displayClusters: [TelegraphCluster] {
        let filtered = clusters.filter { cluster in
            let uid = cluster.primary.uid
            switch filter {
            case .all:
                return true
            case .unread:
                return !readUIDs.contains(uid)
            case .starred:
                return starredUIDs.contains(uid)
            case .later:
                return laterUIDs.contains(uid)
            case .important:
                return ["A", "B"].contains(cluster.primary.level.uppercased())
            }
        }

        return filtered.sorted { lhs, rhs in
            let lp = pinnedUIDs.contains(lhs.primary.uid)
            let rp = pinnedUIDs.contains(rhs.primary.uid)
            if lp != rp { return lp }

            let lu = !readUIDs.contains(lhs.primary.uid)
            let ru = !readUIDs.contains(rhs.primary.uid)
            if lu != ru { return lu }

            if lhs.primary.ctime != rhs.primary.ctime { return lhs.primary.ctime > rhs.primary.ctime }
            return lhs.primary.uid > rhs.primary.uid
        }
    }

    var hasUnreadItems: Bool {
        displayClusters.contains { !readUIDs.contains($0.primary.uid) }
    }

    func refresh(using settings: AppSettings) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let previousUIDs = Set(items.map(\.uid))
            let result = try await APIClient.shared.fetchTelegraph(
                baseURL: settings.serverBaseURL,
                limit: 120,
                sources: settings.selectedSources
            )

            items = result.items
            clusters = buildClusters(from: result.items)
            sourceHealth = result.sources ?? []
            persistLatestItems(result.items)
            lastError = nil

            if hasLoadedSnapshot {
                let newItems = result.items.filter { !previousUIDs.contains($0.uid) }
                await notifyKeywordMatchesIfNeeded(newItems: newItems, settings: settings)
            } else {
                hasLoadedSnapshot = true
            }

            await preloadQuotes(for: Array(displayClusters.prefix(40)))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startAutoRefresh(using settings: AppSettings) {
        stopAutoRefresh()

        autoRefreshTask = Task {
            while !Task.isCancelled {
                await refresh(using: settings)
                let interval = max(3, settings.refreshInterval)
                let nanos = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    func analyze(item: TelegraphItem, settings: AppSettings) async {
        if analyzingUIDs.contains(item.uid) {
            return
        }

        markRead(uid: item.uid)

        let ai = settings.aiSnapshot
        if ai.apiKey.isEmpty {
            lastError = "请先在控制台输入 AI API Key"
            return
        }
        if ai.apiBase.isEmpty {
            lastError = "请先在控制台填写 AI API Base"
            return
        }
        if ai.model.isEmpty {
            lastError = "请先在控制台填写 AI Model"
            return
        }

        analyzingUIDs.insert(item.uid)
        defer { analyzingUIDs.remove(item.uid) }

        do {
            let analysis = try await APIClient.shared.analyze(baseURL: settings.serverBaseURL, item: item, ai: ai)
            analysisByUID[item.uid] = analysis
            persistAnalysisCache()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func workflowState(for item: TelegraphItem) -> TelegraphWorkflowState {
        TelegraphWorkflowState(
            isPinned: pinnedUIDs.contains(item.uid),
            isStarred: starredUIDs.contains(item.uid),
            isReadLater: laterUIDs.contains(item.uid),
            isRead: readUIDs.contains(item.uid)
        )
    }

    func setFilter(_ next: FeedFilterOption) {
        filter = next
        UserDefaults.standard.set(next.rawValue, forKey: filterStoreKey)
    }

    func togglePinned(uid: String) {
        toggleSet(&pinnedUIDs, uid: uid)
        persistSet(pinnedUIDs, key: pinnedStoreKey)
    }

    func toggleStarred(uid: String) {
        toggleSet(&starredUIDs, uid: uid)
        persistSet(starredUIDs, key: starredStoreKey)
    }

    func toggleReadLater(uid: String) {
        toggleSet(&laterUIDs, uid: uid)
        persistSet(laterUIDs, key: laterStoreKey)
    }

    func toggleRead(uid: String) {
        if readUIDs.contains(uid) {
            readUIDs.remove(uid)
        } else {
            readUIDs.insert(uid)
        }
        persistSet(readUIDs, key: readStoreKey)
        objectWillChange.send()
    }

    func markRead(uid: String) {
        if readUIDs.insert(uid).inserted {
            persistSet(readUIDs, key: readStoreKey)
            objectWillChange.send()
        }
    }

    func quotes(for cluster: TelegraphCluster) -> [StockQuote] {
        var orderedCodes: [String] = []
        var seen = Set<String>()

        for item in cluster.items {
            for code in relatedCodes(for: item) where seen.insert(code).inserted {
                orderedCodes.append(code)
            }
        }

        return orderedCodes
            .compactMap { quoteByCode[$0] }
            .sorted { lhs, rhs in
                let la = abs(lhs.changePercent)
                let ra = abs(rhs.changePercent)
                if la != ra { return la > ra }
                return lhs.code < rhs.code
            }
    }

    func generateTodayRecap(force: Bool = false) -> String {
        let key = dayKey(for: Date())
        if !force, let cached = recapByDay[key], !cached.isEmpty {
            latestRecapText = cached
            return cached
        }

        let relevantItems = itemsForDay(Date())
        let output = RecapGenerator.generate(items: relevantItems, date: Date())
        recapByDay[key] = output
        latestRecapText = output
        persistRecapCache()
        return output
    }

    func recapCachedForToday() -> String? {
        recapByDay[dayKey(for: Date())]
    }

    private func itemsForDay(_ date: Date) -> [TelegraphItem] {
        let calendar = Calendar.current
        let dayItems = items.filter { item in
            guard item.ctime > 0 else { return false }
            let itemDate = Date(timeIntervalSince1970: TimeInterval(item.ctime))
            return calendar.isDate(itemDate, inSameDayAs: date)
        }
        if !dayItems.isEmpty {
            return dayItems
        }
        return Array(items.prefix(120))
    }

    private func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func preloadQuotes(for clusters: [TelegraphCluster]) async {
        var candidateCodes: [String] = []
        var seen = Set<String>()

        for cluster in clusters {
            for item in cluster.items {
                for code in relatedCodes(for: item) where seen.insert(code).inserted {
                    candidateCodes.append(code)
                    if candidateCodes.count >= 16 { break }
                }
                if candidateCodes.count >= 16 { break }
            }
            if candidateCodes.count >= 16 { break }
        }

        if candidateCodes.isEmpty { return }

        var fetchList: [String] = []
        let now = Date()
        for code in candidateCodes {
            if let q = quoteByCode[code], now.timeIntervalSince(q.updatedAt) < 35 {
                continue
            }
            fetchList.append(code)
        }

        if fetchList.isEmpty { return }

        await withTaskGroup(of: (String, StockQuote?).self) { group in
            for code in fetchList {
                group.addTask {
                    do {
                        let quote = try await QuoteService.shared.fetchAQuote(code: code)
                        return (code, quote)
                    } catch {
                        return (code, nil)
                    }
                }
            }

            for await (code, quote) in group {
                if let quote {
                    quoteByCode[code] = quote
                }
            }
        }
    }

    private func relatedCodes(for item: TelegraphItem) -> [String] {
        let merged = "\(item.title) \(item.text)"
        return extractAStockCodes(from: merged)
    }

    private func extractAStockCodes(from text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: "(?<!\\d)([0-9]{6})(?!\\d)", options: []) else { return [] }

        var seen = Set<String>()
        var out: [String] = []

        for match in regex.matches(in: text, options: [], range: range) {
            guard match.numberOfRanges > 1 else { continue }
            let code = ns.substring(with: match.range(at: 1))
            if !(code.hasPrefix("6") || code.hasPrefix("0") || code.hasPrefix("3") || code.hasPrefix("2")) {
                continue
            }
            if seen.insert(code).inserted {
                out.append(code)
            }
            if out.count >= 4 { break }
        }

        return out
    }

    private func notifyKeywordMatchesIfNeeded(newItems: [TelegraphItem], settings: AppSettings) async {
        guard settings.keywordAlertEnabled else { return }

        let keywords = settings.keywordList
        guard !keywords.isEmpty else { return }

        var sent = 0
        var changed = false

        for item in newItems {
            if notifiedUIDs.contains(item.uid) {
                continue
            }

            let matched = matchedKeywords(for: item, keywords: keywords)
            if matched.isEmpty {
                continue
            }

            await NotificationManager.shared.sendKeywordAlert(for: item, matchedKeywords: matched)
            notifiedUIDs.insert(item.uid)
            changed = true
            sent += 1

            if sent >= 3 {
                break
            }
        }

        if changed {
            persistNotifiedUIDs()
        }
    }

    private func persistNotifiedUIDs() {
        if notifiedUIDs.count > 1200 {
            let kept = Array(notifiedUIDs.sorted().suffix(1200))
            notifiedUIDs = Set(kept)
        }
        UserDefaults.standard.set(Array(notifiedUIDs), forKey: notifiedUIDStoreKey)
    }

    private func persistLatestItems(_ items: [TelegraphItem]) {
        if let data = try? JSONEncoder().encode(Array(items.prefix(260))) {
            UserDefaults.standard.set(data, forKey: latestItemsStoreKey)
        }
    }

    private func persistAnalysisCache() {
        if analysisByUID.count > 1200 {
            let keys = Array(analysisByUID.keys).sorted()
            let overflow = analysisByUID.count - 1200
            if overflow > 0 {
                for key in keys.prefix(overflow) {
                    analysisByUID.removeValue(forKey: key)
                }
            }
        }
        if let data = try? JSONEncoder().encode(analysisByUID) {
            UserDefaults.standard.set(data, forKey: analysisCacheStoreKey)
        }
    }

    private func persistRecapCache() {
        var sorted = recapByDay.sorted { $0.key < $1.key }
        if sorted.count > 30 {
            sorted = Array(sorted.suffix(30))
            recapByDay = Dictionary(uniqueKeysWithValues: sorted)
        }
        if let data = try? JSONEncoder().encode(recapByDay) {
            UserDefaults.standard.set(data, forKey: recapCacheStoreKey)
        }
    }

    private func matchedKeywords(for item: TelegraphItem, keywords: [String]) -> [String] {
        let haystack = "\(item.title) \(item.text)".lowercased()
        var hits: [String] = []

        for keyword in keywords {
            if haystack.contains(keyword) {
                hits.append(keyword)
            }
            if hits.count >= 3 {
                break
            }
        }

        return hits
    }

    private func buildClusters(from items: [TelegraphItem]) -> [TelegraphCluster] {
        if items.isEmpty { return [] }

        var buckets: [[TelegraphItem]] = []
        var bucketSignatures: [String] = []

        for item in items {
            let signature = clusterSignature(for: item)
            var matchedIndex: Int?

            for idx in buckets.indices {
                guard let representative = buckets[idx].first else { continue }
                if isSameEvent(item, representative, signature, bucketSignatures[idx]) {
                    matchedIndex = idx
                    break
                }
            }

            if let idx = matchedIndex {
                buckets[idx].append(item)
            } else {
                buckets.append([item])
                bucketSignatures.append(signature)
            }
        }

        let merged = buckets.map { group -> TelegraphCluster in
            let sorted = group.sorted(by: itemPrioritySort)
            let id = sorted.first?.uid ?? UUID().uuidString
            return TelegraphCluster(id: id, items: sorted)
        }

        return merged.sorted {
            let a = $0.primary
            let b = $1.primary
            if a.ctime != b.ctime { return a.ctime > b.ctime }
            return a.uid > b.uid
        }
    }

    private func itemPrioritySort(_ lhs: TelegraphItem, _ rhs: TelegraphItem) -> Bool {
        let l = levelRank(lhs.level)
        let r = levelRank(rhs.level)
        if l != r { return l > r }
        if lhs.ctime != rhs.ctime { return lhs.ctime > rhs.ctime }
        return lhs.uid > rhs.uid
    }

    private func levelRank(_ level: String) -> Int {
        switch level.uppercased() {
        case "A":
            return 3
        case "B":
            return 2
        default:
            return 1
        }
    }

    private func clusterSignature(for item: TelegraphItem) -> String {
        let t = normalizeForCluster(item.displayTitle)
        if t.count >= 8 {
            return "t:\(String(t.prefix(64)))"
        }

        let x = normalizeForCluster(item.text)
        if x.count >= 16 {
            return "x:\(String(x.prefix(36)))"
        }

        return "u:\(item.uid)"
    }

    private func isSameEvent(_ lhs: TelegraphItem, _ rhs: TelegraphItem, _ lhsSignature: String, _ rhsSignature: String) -> Bool {
        if lhs.ctime > 0, rhs.ctime > 0, abs(lhs.ctime - rhs.ctime) > 45 * 60 {
            return false
        }

        if lhsSignature == rhsSignature, !lhsSignature.hasPrefix("u:") {
            return true
        }

        let lt = normalizeForCluster(lhs.displayTitle)
        let rt = normalizeForCluster(rhs.displayTitle)
        if lt.count >= 8, lt == rt {
            return true
        }

        let lx = normalizeForCluster(lhs.text)
        let rx = normalizeForCluster(rhs.text)
        if lx.count >= 24, rx.count >= 24, String(lx.prefix(28)) == String(rx.prefix(28)) {
            return true
        }

        return false
    }

    private func normalizeForCluster(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{Han}a-z0-9%]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toggleSet(_ set: inout Set<String>, uid: String) {
        if set.contains(uid) {
            set.remove(uid)
        } else {
            set.insert(uid)
        }
    }

    private func persistSet(_ set: Set<String>, key: String) {
        let clipped = Array(set.sorted().suffix(1800))
        UserDefaults.standard.set(clipped, forKey: key)
        objectWillChange.send()
    }

    private static func loadAnalysisCache(key: String) -> [String: AIAnalysis] {
        guard let raw = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: AIAnalysis].self, from: raw)) ?? [:]
    }

    private static func loadRecapCache(key: String) -> [String: String] {
        guard let raw = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: raw)) ?? [:]
    }

    private static func loadCachedItems(key: String) -> [TelegraphItem] {
        guard let raw = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TelegraphItem].self, from: raw)) ?? []
    }
}
