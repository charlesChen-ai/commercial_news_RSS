import Foundation

enum RefreshTrigger {
    case manual
    case auto
    case startup
}

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var items: [TelegraphItem] = []
    @Published var clusters: [TelegraphCluster] = []
    @Published var sourceHealth: [SourceHealth] = []
    @Published var feedError: String?
    @Published var aiError: String?
    @Published var isLoading = false
    @Published var analyzingUIDs: Set<String> = []
    @Published var analysisByUID: [String: AIAnalysis] = [:]
    @Published var quoteByCode: [String: StockQuote] = [:]
    @Published var filter: FeedFilterOption = .all
    @Published private(set) var displayClusters: [TelegraphCluster] = []
    @Published var latestRecapText: String = ""
    @Published var lastSuccessfulRefreshAt: Date?
    @Published var pendingAIJobs = 0

    private let persistence: FeedPersistenceStore
    private let retryQueue: AIRetryQueueStore
    private var notifiedUIDs: Set<String> = []
    private var pinnedUIDs: Set<String> = []
    private var starredUIDs: Set<String> = []
    private var laterUIDs: Set<String> = []
    private var readUIDs: Set<String> = []
    private var recapByDay: [String: String] = [:]
    private var hasLoadedSnapshot = false
    private var autoRefreshTask: Task<Void, Never>?
    private var manualRefreshPending = false

    init(scope: String = "home", persistence: FeedPersistenceStore? = nil, retryQueue: AIRetryQueueStore = .shared) {
        self.persistence = persistence ?? FeedPersistenceStore(scope: scope)
        self.retryQueue = retryQueue

        let state = self.persistence.loadState()
        notifiedUIDs = state.notifiedUIDs
        pinnedUIDs = state.pinnedUIDs
        starredUIDs = state.starredUIDs
        laterUIDs = state.laterUIDs
        readUIDs = state.readUIDs
        recapByDay = state.recapByDay
        filter = state.filter
        analysisByUID = state.analysisByUID
        lastSuccessfulRefreshAt = state.lastSuccessAt

        let cachedItems = normalizedItems(from: state.latestItems)
        if !cachedItems.isEmpty {
            items = cachedItems
            clusters = TelegraphClusterer.buildClusters(from: cachedItems)
            recomputeDisplayClusters()
            hasLoadedSnapshot = true
        }

        pendingAIJobs = retryQueue.pendingCount
    }

    var hasUnreadItems: Bool {
        displayClusters.contains { !readUIDs.contains($0.primary.uid) }
    }

    func refresh(using settings: AppSettings, trigger: RefreshTrigger = .manual) async {
        if isLoading {
            if trigger == .manual, !manualRefreshPending {
                manualRefreshPending = true
                // Wait for in-flight refresh to finish, then run one manual refresh.
                for _ in 0..<24 where isLoading {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                manualRefreshPending = false
                if isLoading { return }
            } else {
                return
            }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let previousUIDs = Set(items.map(\.uid))
            let result = try await fetchTelegraphWithResilience(using: settings, trigger: trigger)
            let fetchedItems = normalizedItems(from: result.items)

            // Avoid blanking the timeline when upstream returns an empty payload transiently.
            if fetchedItems.isEmpty, !items.isEmpty {
                sourceHealth = result.sources ?? []
                let prefix: String
                switch trigger {
                case .manual:
                    prefix = "手动刷新"
                case .auto:
                    prefix = "自动刷新"
                case .startup:
                    prefix = "启动刷新"
                }
                feedError = "\(prefix)返回空数据，已保留本地缓存内容。"
                await preloadQuotes(for: Array(displayClusters.prefix(40)))
                await drainAIQueueIfPossible(using: settings, limit: trigger == .manual ? 3 : 1)
                return
            }

            items = fetchedItems
            clusters = TelegraphClusterer.buildClusters(from: fetchedItems)
            recomputeDisplayClusters()
            sourceHealth = result.sources ?? []
            persistLatestItems(fetchedItems)
            feedError = nil
            lastSuccessfulRefreshAt = Date()
            persistence.saveLastSuccess(lastSuccessfulRefreshAt)

            if hasLoadedSnapshot {
                let newItems = fetchedItems.filter { !previousUIDs.contains($0.uid) }
                await notifyKeywordMatchesIfNeeded(newItems: newItems, settings: settings)
            } else {
                hasLoadedSnapshot = true
            }

            await preloadQuotes(for: Array(displayClusters.prefix(40)))
            await drainAIQueueIfPossible(using: settings, limit: trigger == .manual ? 3 : 1)
        } catch {
            // Keep previous content while clearly surfacing network/service failures.
            feedError = refreshErrorMessage(error, trigger: trigger)
        }
    }

    func startAutoRefresh(using settings: AppSettings) {
        stopAutoRefresh()

        autoRefreshTask = Task {
            await refresh(using: settings, trigger: .startup)
            var nextTick = Date().timeIntervalSince1970 + max(1, settings.refreshInterval)
            while !Task.isCancelled {
                let now = Date().timeIntervalSince1970
                let wait = max(0.05, nextTick - now)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                let started = Date().timeIntervalSince1970
                await refresh(using: settings, trigger: .auto)
                await drainAIQueueIfPossible(using: settings, limit: 2)
                let finished = Date().timeIntervalSince1970
                let interval = max(1, settings.refreshInterval)
                let nominalNext = started + interval
                nextTick = max(nominalNext, finished + 0.15)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func fetchTelegraphWithResilience(using settings: AppSettings, trigger: RefreshTrigger) async throws -> TelegraphResponse {
        let selected = settings.selectedSources

        do {
            return try await APIClient.shared.fetchTelegraph(
                baseURL: settings.effectiveServerBaseURL,
                limit: 120,
                sources: selected
            )
        } catch {
            let primaryError = error
            guard trigger == .manual else {
                throw primaryError
            }

            try? await Task.sleep(nanoseconds: 650_000_000)

            do {
                return try await APIClient.shared.fetchTelegraph(
                    baseURL: settings.effectiveServerBaseURL,
                    limit: 120,
                    sources: selected
                )
            } catch {
                let secondError = error
                let fallback = fallbackSources(for: selected)
                if fallback != selected {
                    do {
                        let partial = try await APIClient.shared.fetchTelegraph(
                            baseURL: settings.effectiveServerBaseURL,
                            limit: 120,
                            sources: fallback
                        )
                        return partial
                    } catch {
                        throw secondError
                    }
                }
                throw secondError
            }
        }
    }

    private func fallbackSources(for selected: [NewsSource]) -> [NewsSource] {
        let removeTHS = selected.filter { $0 != .ths }
        if removeTHS.count >= 1, removeTHS.count < selected.count {
            return removeTHS
        }

        let removeUnstable = selected.filter { $0 != .ths && $0 != .wscn }
        if removeUnstable.count >= 1, removeUnstable.count < selected.count {
            return removeUnstable
        }

        return selected
    }

    func analyze(item: TelegraphItem, settings: AppSettings) async {
        if analyzingUIDs.contains(item.uid) {
            return
        }

        let ai = settings.aiSnapshot
        if ai.apiKey.isEmpty {
            aiError = "请先在控制台输入 AI API Key"
            return
        }
        if ai.apiBase.isEmpty {
            aiError = "请先在控制台填写 AI API Base"
            return
        }
        if ai.model.isEmpty {
            aiError = "请先在控制台填写 AI Model"
            return
        }

        analyzingUIDs.insert(item.uid)
        defer { analyzingUIDs.remove(item.uid) }

        do {
            let analysis = try await APIClient.shared.analyze(baseURL: settings.effectiveServerBaseURL, item: item, ai: ai)
            analysisByUID[item.uid] = analysis
            persistAnalysisCache()
            aiError = nil
            pendingAIJobs = retryQueue.pendingCount
        } catch {
            if settings.aiRetryQueueEnabled, shouldQueueForRetry(error) {
                _ = retryQueue.enqueue(item)
                pendingAIJobs = retryQueue.pendingCount
                aiError = "AI 请求失败，已加入重试队列（待重试 \(pendingAIJobs) 条）"
            } else {
                aiError = error.localizedDescription
            }
        }
    }

    func retryQueuedAnalyses(using settings: AppSettings) async {
        await drainAIQueueIfPossible(using: settings, limit: 8, force: true)
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
        recomputeDisplayClusters()
        persistence.saveFilter(next)
    }

    func togglePinned(uid: String) {
        toggleSet(&pinnedUIDs, uid: uid)
        persistSet(pinnedUIDs, bucket: .pinned)
        recomputeDisplayClusters()
    }

    func toggleStarred(uid: String) {
        toggleSet(&starredUIDs, uid: uid)
        persistSet(starredUIDs, bucket: .starred)
        recomputeDisplayClusters()
    }

    func toggleReadLater(uid: String) {
        toggleSet(&laterUIDs, uid: uid)
        persistSet(laterUIDs, bucket: .later)
        recomputeDisplayClusters()
    }

    func toggleRead(uid: String) {
        if readUIDs.contains(uid) {
            readUIDs.remove(uid)
        } else {
            readUIDs.insert(uid)
        }
        persistSet(readUIDs, bucket: .read)
        objectWillChange.send()
    }

    func markRead(uid: String) {
        if readUIDs.insert(uid).inserted {
            persistSet(readUIDs, bucket: .read)
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
        notifiedUIDs = persistence.saveUIDSet(notifiedUIDs, bucket: .notified, limit: 1200)
    }

    private func persistLatestItems(_ items: [TelegraphItem]) {
        persistence.saveLatestItems(items, limit: 260)
    }

    private func persistAnalysisCache() {
        analysisByUID = persistence.saveAnalysisMap(analysisByUID, limit: 1200)
    }

    private func persistRecapCache() {
        recapByDay = persistence.saveRecapMap(recapByDay, keepDays: 30)
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

    private func toggleSet(_ set: inout Set<String>, uid: String) {
        if set.contains(uid) {
            set.remove(uid)
        } else {
            set.insert(uid)
        }
    }

    private func persistSet(_ set: Set<String>, bucket: FeedUIDBucket) {
        switch bucket {
        case .pinned:
            pinnedUIDs = persistence.saveUIDSet(set, bucket: .pinned)
        case .starred:
            starredUIDs = persistence.saveUIDSet(set, bucket: .starred)
        case .later:
            laterUIDs = persistence.saveUIDSet(set, bucket: .later)
        case .read:
            readUIDs = persistence.saveUIDSet(set, bucket: .read)
        case .notified:
            notifiedUIDs = persistence.saveUIDSet(set, bucket: .notified)
        }
        objectWillChange.send()
    }

    private func recomputeDisplayClusters() {
        let prepared = clusters
            .map(reorderedClusterByContent)
            .filter(isRenderableCluster)

        let filtered = prepared.filter { cluster in
            let uid = cluster.primary.uid
            switch filter {
            case .all:
                return true
            case .starred:
                return starredUIDs.contains(uid)
            case .later:
                return laterUIDs.contains(uid)
            }
        }

        displayClusters = filtered.sorted { lhs, rhs in
            let lp = pinnedUIDs.contains(lhs.primary.uid)
            let rp = pinnedUIDs.contains(rhs.primary.uid)
            if lp != rp { return lp }

            if lhs.primary.ctime != rhs.primary.ctime { return lhs.primary.ctime > rhs.primary.ctime }
            return lhs.primary.uid > rhs.primary.uid
        }
    }

    private func reorderedClusterByContent(_ cluster: TelegraphCluster) -> TelegraphCluster {
        let sorted = cluster.items.sorted { lhs, rhs in
            let lc = contentScore(lhs)
            let rc = contentScore(rhs)
            if lc != rc { return lc > rc }

            let lt = lhs.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).count
            let rt = rhs.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).count
            if lt != rt { return lt > rt }

            if lhs.ctime != rhs.ctime { return lhs.ctime > rhs.ctime }
            return lhs.uid > rhs.uid
        }
        let id = sorted.first?.uid ?? cluster.id
        return TelegraphCluster(id: id, items: sorted)
    }

    private func isRenderableCluster(_ cluster: TelegraphCluster) -> Bool {
        cluster.items.contains(where: isRenderableItem)
    }

    private func isRenderableItem(_ item: TelegraphItem) -> Bool {
        let title = canonicalReadableText(item.title)
        let text = canonicalReadableText(item.text)
        if title.count >= 2 { return true }
        if text.count >= 8 { return true }
        return false
    }

    private func contentScore(_ item: TelegraphItem) -> Int {
        let title = canonicalReadableText(item.title)
        let text = canonicalReadableText(item.text)
        let titleScore = min(80, title.count * 2)
        let textScore = min(220, text.count)
        return titleScore + textScore
    }

    private func normalizedItems(from raw: [TelegraphItem]) -> [TelegraphItem] {
        if raw.isEmpty { return [] }

        var seenUID = Set<String>()
        var seenFingerprint = Set<String>()
        var out: [TelegraphItem] = []
        out.reserveCapacity(raw.count)

        for item in raw {
            let title = canonicalReadableText(item.title)
            let text = canonicalReadableText(item.text)

            // Drop pseudo-empty records (only spaces/markup/noise).
            guard !(title.isEmpty && text.isEmpty) else { continue }
            guard hasMeaningfulCharacter(in: "\(title)\(text)") else { continue }
            guard title.count >= 2 || text.count >= 8 || (text.count >= 4 && text.contains(where: \.isNumber)) else { continue }

            guard seenUID.insert(item.uid).inserted else { continue }

            // De-duplicate near-identical items with different uid from upstream retries.
            let fp = "\(String(title.prefix(48)))|\(String(text.prefix(96)))|\(item.source)"
            guard seenFingerprint.insert(fp).inserted else { continue }

            out.append(item)
        }

        return out
    }

    private func canonicalReadableText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^【[^】]{2,30}】", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^(财联社|新浪财经|华尔街见闻|同花顺|东方财富)(\\d{1,2}月\\d{1,2}日)?电[，,:：\\s]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\u200B\\u200C\\u200D\\u2060\\uFEFF]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasMeaningfulCharacter(in text: String) -> Bool {
        text.range(of: "[\\p{Han}A-Za-z0-9]", options: .regularExpression) != nil
    }

    private func drainAIQueueIfPossible(using settings: AppSettings, limit: Int, force: Bool = false) async {
        pendingAIJobs = retryQueue.pendingCount
        guard pendingAIJobs > 0 else { return }
        guard settings.aiRetryQueueEnabled else { return }

        let ai = settings.aiSnapshot
        guard !ai.apiKey.isEmpty, !ai.apiBase.isEmpty, !ai.model.isEmpty else { return }

        let jobs = retryQueue.readyJobs(limit: limit, ignoreSchedule: force)
        guard !jobs.isEmpty else { return }

        var changedAnalysis = false
        for job in jobs {
            let uid = job.item.uid
            if analyzingUIDs.contains(uid) {
                continue
            }

            analyzingUIDs.insert(uid)
            do {
                let analysis = try await APIClient.shared.analyze(
                    baseURL: settings.effectiveServerBaseURL,
                    item: job.item,
                    ai: ai
                )
                analysisByUID[uid] = analysis
                retryQueue.markSucceeded(jobID: job.id)
                changedAnalysis = true
            } catch {
                retryQueue.markFailed(jobID: job.id, error: error)
            }
            analyzingUIDs.remove(uid)
        }

        if changedAnalysis {
            persistAnalysisCache()
        }
        pendingAIJobs = retryQueue.pendingCount
    }

    private func shouldQueueForRetry(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("api key") || message.contains("401") || message.contains("403") {
            return false
        }

        let retryHints = [
            "timeout", "timed out", "network", "connection",
            "not connected", "offline", "cannot find host",
            "http 429", "http 500", "http 502", "http 503", "http 504"
        ]
        return retryHints.contains { message.contains($0) }
    }

    private func refreshErrorMessage(_ error: Error, trigger: RefreshTrigger) -> String {
        let core = error.localizedDescription
        let prefix: String
        switch trigger {
        case .manual:
            prefix = "刷新失败"
        case .auto:
            prefix = "自动刷新失败"
        case .startup:
            prefix = "初始化加载失败"
        }

        if let lastSuccessfulRefreshAt {
            return "\(prefix)：\(core)。已保留旧数据（上次成功 \(refreshTimeText(lastSuccessfulRefreshAt))）。"
        }
        return "\(prefix)：\(core)"
    }

    private func refreshTimeText(_ date: Date) -> String {
        Self.refreshTimeFormatter.string(from: date)
    }

    private static let refreshTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
