import Foundation

enum RefreshTrigger: String, Equatable {
    case manual
    case auto
    case startup

    var displayText: String {
        switch self {
        case .manual:
            return "手动刷新"
        case .auto:
            return "自动刷新"
        case .startup:
            return "启动刷新"
        }
    }
}

enum FeedRefreshState: Equatable {
    case idle
    case loading(RefreshTrigger)
    case stagingPending(Int)
    case applyingPending
    case fallbackUsingCache

    var displayText: String {
        switch self {
        case .idle:
            return "空闲"
        case .loading(let trigger):
            return trigger.displayText
        case .stagingPending(let count):
            return "待插入 \(count) 条"
        case .applyingPending:
            return "插入新消息"
        case .fallbackUsingCache:
            return "缓存兜底"
        }
    }
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
    @Published var pendingNewItemsCount = 0
    @Published private(set) var refreshState: FeedRefreshState = .idle
    @Published private(set) var lastRefreshDurationMS = 0

    private let scope: String
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
    private var latestCursor: String?
    private var cloudStateObserver: NSObjectProtocol?
    private var sharedSnapshotObserver: NSObjectProtocol?
    private var stagedNewItems: [TelegraphItem] = []
    private var stagedPreparedData: PreparedFeedData?

    private struct PreparedFeedData {
        let normalizedFetched: [TelegraphItem]
        let mergedItems: [TelegraphItem]
        let clusters: [TelegraphCluster]
        let displayClusters: [TelegraphCluster]
    }

    private static let processingQueue = DispatchQueue(
        label: "cls.feed.processing",
        qos: .userInitiated
    )

    init(scope: String = "home", persistence: FeedPersistenceStore? = nil, retryQueue: AIRetryQueueStore = .shared) {
        self.scope = scope
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
        latestCursor = Self.normalizedCursor(state.latestCursor)

        var seedItems = Self.normalizedItems(from: state.latestItems)
        if seedItems.isEmpty, scope != "home" {
            let homeSnapshot = FeedPersistenceStore(scope: "home").loadState().latestItems
            seedItems = Self.normalizedItems(from: homeSnapshot)
        }

        if !seedItems.isEmpty {
            items = seedItems
            clusters = TelegraphClusterer.buildClusters(from: seedItems)
            displayClusters = Self.computeDisplayClusters(
                from: clusters,
                filter: filter,
                pinnedUIDs: pinnedUIDs,
                starredUIDs: starredUIDs,
                laterUIDs: laterUIDs
            )
            hasLoadedSnapshot = true
        }
        if latestCursor == nil, !state.latestItems.isEmpty, let first = seedItems.first {
            latestCursor = TelegraphCursor.encode(ctime: first.ctime, uid: first.uid)
            self.persistence.saveCursor(latestCursor)
        }

        pendingAIJobs = retryQueue.pendingCount

        cloudStateObserver = NotificationCenter.default.addObserver(
            forName: .cloudStateDidApply,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadCloudSyncedState()
            }
        }

        sharedSnapshotObserver = NotificationCenter.default.addObserver(
            forName: .feedSnapshotDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard self.scope != "home" else { return }
            guard let sourceScope = note.userInfo?["scope"] as? String else { return }
            guard sourceScope == "home" else { return }
            Task { @MainActor in
                await self.ingestSharedHomeSnapshot()
            }
        }
    }

    deinit {
        if let cloudStateObserver {
            NotificationCenter.default.removeObserver(cloudStateObserver)
        }
        if let sharedSnapshotObserver {
            NotificationCenter.default.removeObserver(sharedSnapshotObserver)
        }
    }

    var hasUnreadItems: Bool {
        displayClusters.contains { !readUIDs.contains($0.primary.uid) }
    }

    var hasPendingNewItems: Bool {
        pendingNewItemsCount > 0
    }

    var pendingHeadlineNewItemsCount: Int {
        guard !stagedNewItems.isEmpty else { return 0 }
        var count = 0
        for item in stagedNewItems {
            let level = item.level.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if level == "A" || level == "B" {
                count += 1
            }
        }
        return count
    }

    var refreshStateText: String {
        refreshState.displayText
    }

    var isApplyingPendingInsertion: Bool {
        if case .applyingPending = refreshState {
            return true
        }
        return false
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

        let startedAt = CFAbsoluteTimeGetCurrent()
        var stateAtExit = refreshState
        var refreshSucceeded = false

        isLoading = true
        refreshState = .loading(trigger)
        defer {
            isLoading = false
            let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())
            lastRefreshDurationMS = max(0, elapsedMS)
            AppTelemetryCenter.shared.record(
                name: "feed_refresh",
                value: Double(lastRefreshDurationMS),
                meta: [
                    "scope": scope,
                    "trigger": trigger.rawValue,
                    "state": stateAtExit.displayText,
                    "ok": refreshSucceeded ? "1" : "0",
                    "pending": "\(pendingNewItemsCount)"
                ]
            )
            refreshState = stateAtExit
        }

        do {
            let previousUIDs = Set(items.map(\.uid))
            var requestCursor = Self.normalizedCursor(latestCursor)
            let result: TelegraphResponse

            do {
                result = try await fetchTelegraphWithResilience(
                    using: settings,
                    trigger: trigger,
                    cursor: requestCursor
                )
            } catch {
                if requestCursor != nil, isInvalidCursorError(error) {
                    requestCursor = nil
                    latestCursor = nil
                    persistence.saveCursor(nil)
                    result = try await fetchTelegraphWithResilience(
                        using: settings,
                        trigger: trigger,
                        cursor: nil
                    )
                } else {
                    throw error
                }
            }

            let normalizedFetched = Self.normalizedItems(from: result.items)
            let incrementalResponse = isIncrementalResponse(result, requestedCursor: requestCursor)
            let pipelineItems: [TelegraphItem]
            if incrementalResponse {
                pipelineItems = Self.mergeIncrementalItems(normalizedFetched, onto: items, cap: 320)
            } else {
                pipelineItems = result.items
            }

            let prepared = await prepareFeedData(
                from: pipelineItems,
                previousItems: items,
                filter: filter,
                pinnedUIDs: pinnedUIDs,
                starredUIDs: starredUIDs,
                laterUIDs: laterUIDs,
                trigger: trigger
            )
            let nextCursor = resolveNextCursor(
                response: result,
                preparedItems: prepared.mergedItems,
                requestedCursor: requestCursor
            )
            latestCursor = nextCursor
            persistence.saveCursor(nextCursor)

            let newlyFetched = normalizedFetched.filter { !previousUIDs.contains($0.uid) }
            if shouldStageIncomingItems(trigger: trigger, newItems: newlyFetched) {
                stageIncomingItems(newlyFetched, prepared: prepared)
                stateAtExit = .stagingPending(pendingNewItemsCount)
                refreshSucceeded = true
                persistLatestItems(prepared.mergedItems)
                sourceHealth = result.sources ?? []
                feedError = nil
                lastSuccessfulRefreshAt = Date()
                persistence.saveLastSuccess(lastSuccessfulRefreshAt)
                await preloadQuotes(for: Array(displayClusters.prefix(40)))
                await drainAIQueueIfPossible(using: settings, limit: trigger == .manual ? 3 : 1)
                return
            }

            // Avoid blanking the timeline when upstream returns an empty payload transiently.
            if normalizedFetched.isEmpty, !items.isEmpty {
                sourceHealth = result.sources ?? []
                feedError = nil
                stateAtExit = .idle
                refreshSucceeded = true
                await preloadQuotes(for: Array(displayClusters.prefix(40)))
                await drainAIQueueIfPossible(using: settings, limit: trigger == .manual ? 3 : 1)
                return
            }

            items = prepared.mergedItems
            clusters = prepared.clusters
            displayClusters = prepared.displayClusters
            clearStagedIncomingItems()
            let insertedFavorites = syncKeywordHitsToFavorites(using: settings, recomputeAfterSync: false)
            if insertedFavorites > 0, filter == .starred {
                recomputeDisplayClusters()
            }
            sourceHealth = result.sources ?? []
            persistLatestItems(prepared.mergedItems)
            feedError = nil
            lastSuccessfulRefreshAt = Date()
            persistence.saveLastSuccess(lastSuccessfulRefreshAt)

            if hasLoadedSnapshot {
                await notifyKeywordMatchesIfNeeded(newItems: newlyFetched, settings: settings)
            } else {
                hasLoadedSnapshot = true
            }

            await preloadQuotes(for: Array(displayClusters.prefix(40)))
            await drainAIQueueIfPossible(using: settings, limit: trigger == .manual ? 3 : 1)
            stateAtExit = .idle
            refreshSucceeded = true
        } catch {
            AppTelemetryCenter.shared.record(
                name: "feed_refresh_error",
                meta: [
                    "scope": scope,
                    "trigger": trigger.rawValue,
                    "message": String(error.localizedDescription.prefix(120))
                ]
            )

            // Silent fallback: keep current content first, then local snapshot.
            if items.isEmpty {
                let snapshot = Self.normalizedItems(from: persistence.loadState().latestItems)
                if !snapshot.isEmpty {
                    items = snapshot
                    clusters = TelegraphClusterer.buildClusters(from: snapshot)
                    displayClusters = Self.computeDisplayClusters(
                        from: clusters,
                        filter: filter,
                        pinnedUIDs: pinnedUIDs,
                        starredUIDs: starredUIDs,
                        laterUIDs: laterUIDs
                    )
                }
            }

            if !items.isEmpty {
                feedError = nil
                stateAtExit = .fallbackUsingCache
                await preloadQuotes(for: Array(displayClusters.prefix(40)))
                await drainAIQueueIfPossible(using: settings, limit: trigger == .manual ? 3 : 1)
                return
            }

            // No user-facing refresh error popups; keep failure internal.
            feedError = nil
            stateAtExit = .idle
        }
    }

    @discardableResult
    func applyPendingNewItems(using settings: AppSettings) async -> Int {
        guard !stagedNewItems.isEmpty else { return 0 }

        refreshState = .applyingPending
        let incoming = stagedNewItems
        let stagedPrepared = stagedPreparedData
        clearStagedIncomingItems()

        let prepared: PreparedFeedData
        if let stagedPrepared {
            let nextDisplay = Self.computeDisplayClusters(
                from: stagedPrepared.clusters,
                filter: filter,
                pinnedUIDs: pinnedUIDs,
                starredUIDs: starredUIDs,
                laterUIDs: laterUIDs
            )
            prepared = PreparedFeedData(
                normalizedFetched: stagedPrepared.normalizedFetched,
                mergedItems: stagedPrepared.mergedItems,
                clusters: stagedPrepared.clusters,
                displayClusters: nextDisplay
            )
        } else {
            let merged = Self.mergeIncrementalItems(incoming, onto: items, cap: 320)
            prepared = await prepareFeedData(
                from: merged,
                previousItems: items,
                filter: filter,
                pinnedUIDs: pinnedUIDs,
                starredUIDs: starredUIDs,
                laterUIDs: laterUIDs,
                trigger: .manual
            )
        }

        items = prepared.mergedItems
        clusters = prepared.clusters
        displayClusters = prepared.displayClusters
        persistLatestItems(prepared.mergedItems)
        lastSuccessfulRefreshAt = Date()
        persistence.saveLastSuccess(lastSuccessfulRefreshAt)
        _ = syncKeywordHitsToFavorites(using: settings, recomputeAfterSync: false)
        let quoteTargets = Array(displayClusters.prefix(40))
        Task { [quoteTargets] in
            await self.preloadQuotes(for: quoteTargets)
        }
        refreshState = .idle
        AppTelemetryCenter.shared.record(
            name: "pending_apply",
            value: Double(incoming.count),
            meta: [
                "scope": scope,
                "inserted": "\(incoming.count)"
            ]
        )
        return incoming.count
    }

    func startAutoRefresh(using settings: AppSettings, immediateRefresh: Bool = true) {
        stopAutoRefresh()

        autoRefreshTask = Task {
            if immediateRefresh {
                await refresh(using: settings, trigger: .startup)
            }
            var nextTick = Date().timeIntervalSince1970 + max(1, settings.refreshInterval)
            if !immediateRefresh {
                nextTick = Date().timeIntervalSince1970 + min(1.2, max(0.45, settings.refreshInterval * 0.4))
            }
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

    func invalidateCursor() {
        latestCursor = nil
        persistence.saveCursor(nil)
    }

    private func fetchTelegraphWithResilience(
        using settings: AppSettings,
        trigger: RefreshTrigger,
        cursor: String?
    ) async throws -> TelegraphResponse {
        let selected = settings.selectedSources
        if selected.isEmpty {
            return TelegraphResponse(
                ok: true,
                fetchedAt: nil,
                items: [],
                sources: [],
                selectedSources: [],
                cursor: cursor,
                nextCursor: cursor,
                incremental: true
            )
        }

        do {
            return try await APIClient.shared.fetchTelegraph(
                baseURL: settings.effectiveServerBaseURL,
                limit: 120,
                sources: selected,
                cursor: cursor
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
                    sources: selected,
                    cursor: cursor
                )
            } catch {
                let secondError = error
                let fallback = fallbackSources(for: selected)
                if fallback != selected {
                    do {
                        let partial = try await APIClient.shared.fetchTelegraph(
                            baseURL: settings.effectiveServerBaseURL,
                            limit: 120,
                            sources: fallback,
                            cursor: cursor
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

    private func isIncrementalResponse(_ response: TelegraphResponse, requestedCursor: String?) -> Bool {
        if response.incremental == true {
            return true
        }
        return Self.normalizedCursor(requestedCursor) != nil
    }

    private func resolveNextCursor(
        response: TelegraphResponse,
        preparedItems: [TelegraphItem],
        requestedCursor: String?
    ) -> String? {
        if let next = Self.normalizedCursor(response.nextCursor) {
            return next
        }
        if isIncrementalResponse(response, requestedCursor: requestedCursor),
           let requestCursor = Self.normalizedCursor(requestedCursor) {
            return requestCursor
        }
        if let first = preparedItems.first {
            return TelegraphCursor.encode(ctime: first.ctime, uid: first.uid)
        }
        return nil
    }

    private func isInvalidCursorError(_ error: Error) -> Bool {
        if let api = error as? APIClientError,
           case .badServerResponse(let reason) = api {
            let lowered = reason.lowercased()
            return lowered.contains("invalid_cursor") || lowered.contains("cursor_expired")
        }
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains("invalid_cursor") || lowered.contains("cursor_expired")
    }

    private func prepareFeedData(
        from rawItems: [TelegraphItem],
        previousItems: [TelegraphItem],
        filter: FeedFilterOption,
        pinnedUIDs: Set<String>,
        starredUIDs: Set<String>,
        laterUIDs: Set<String>,
        trigger: RefreshTrigger
    ) async -> PreparedFeedData {
        await withCheckedContinuation { continuation in
            Self.processingQueue.async {
                let normalizedFetched = Self.normalizedItems(from: rawItems)
                let mergedItems = Self.stabilizedItems(
                    from: normalizedFetched,
                    previousItems: previousItems,
                    trigger: trigger
                )
                let nextClusters = TelegraphClusterer.buildClusters(from: mergedItems)
                let nextDisplay = Self.computeDisplayClusters(
                    from: nextClusters,
                    filter: filter,
                    pinnedUIDs: pinnedUIDs,
                    starredUIDs: starredUIDs,
                    laterUIDs: laterUIDs
                )
                continuation.resume(
                    returning: PreparedFeedData(
                        normalizedFetched: normalizedFetched,
                        mergedItems: mergedItems,
                        clusters: nextClusters,
                        displayClusters: nextDisplay
                    )
                )
            }
        }
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

    @discardableResult
    func syncKeywordHitsToFavorites(using settings: AppSettings) -> Int {
        syncKeywordHitsToFavorites(using: settings, recomputeAfterSync: true)
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

    private func ingestSharedHomeSnapshot() async {
        guard scope != "home" else { return }
        guard !isLoading else { return }

        let homeItems = Self.normalizedItems(from: FeedPersistenceStore(scope: "home").loadState().latestItems)
        guard !homeItems.isEmpty else { return }

        let merged = Self.mergeIncrementalItems(homeItems, onto: items, cap: 320)
        guard merged != items else { return }

        let prepared = await prepareFeedData(
            from: merged,
            previousItems: items,
            filter: filter,
            pinnedUIDs: pinnedUIDs,
            starredUIDs: starredUIDs,
            laterUIDs: laterUIDs,
            trigger: .auto
        )

        items = prepared.mergedItems
        clusters = prepared.clusters
        displayClusters = prepared.displayClusters
        persistLatestItems(prepared.mergedItems)
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

    @discardableResult
    private func syncKeywordHitsToFavorites(using settings: AppSettings, recomputeAfterSync: Bool) -> Int {
        let keywords = settings.keywordList
        guard !keywords.isEmpty else { return 0 }

        var inserted = 0
        for cluster in clusters {
            let matched = cluster.items.contains { item in
                !matchedKeywords(for: item, keywords: keywords).isEmpty
            }
            guard matched else { continue }

            if starredUIDs.insert(cluster.primary.uid).inserted {
                inserted += 1
            }
        }

        guard inserted > 0 else { return 0 }

        starredUIDs = persistence.saveUIDSet(starredUIDs, bucket: .starred)
        if recomputeAfterSync {
            recomputeDisplayClusters()
        }
        return inserted
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
        displayClusters = Self.computeDisplayClusters(
            from: clusters,
            filter: filter,
            pinnedUIDs: pinnedUIDs,
            starredUIDs: starredUIDs,
            laterUIDs: laterUIDs
        )
    }

    private nonisolated static func computeDisplayClusters(
        from clusters: [TelegraphCluster],
        filter: FeedFilterOption,
        pinnedUIDs: Set<String>,
        starredUIDs: Set<String>,
        laterUIDs: Set<String>
    ) -> [TelegraphCluster] {
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

        return filtered.sorted { lhs, rhs in
            let lp = pinnedUIDs.contains(lhs.primary.uid)
            let rp = pinnedUIDs.contains(rhs.primary.uid)
            if lp != rp { return lp }

            if lhs.primary.ctime != rhs.primary.ctime { return lhs.primary.ctime > rhs.primary.ctime }
            return lhs.primary.uid > rhs.primary.uid
        }
    }

    private nonisolated static func reorderedClusterByContent(_ cluster: TelegraphCluster) -> TelegraphCluster {
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

    private nonisolated static func isRenderableCluster(_ cluster: TelegraphCluster) -> Bool {
        cluster.items.contains(where: isRenderableItem)
    }

    private nonisolated static func isRenderableItem(_ item: TelegraphItem) -> Bool {
        let title = canonicalReadableText(item.title)
        let text = canonicalReadableText(item.text)
        if title.count >= 2 { return true }
        if text.count >= 8 { return true }
        return false
    }

    private nonisolated static func contentScore(_ item: TelegraphItem) -> Int {
        let title = canonicalReadableText(item.title)
        let text = canonicalReadableText(item.text)
        let titleScore = min(80, title.count * 2)
        let textScore = min(220, text.count)
        return titleScore + textScore
    }

    private nonisolated static func normalizedItems(from raw: [TelegraphItem]) -> [TelegraphItem] {
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

    private nonisolated static func mergeIncrementalItems(
        _ incoming: [TelegraphItem],
        onto existing: [TelegraphItem],
        cap: Int
    ) -> [TelegraphItem] {
        if incoming.isEmpty { return Array(existing.prefix(cap)) }

        var merged: [TelegraphItem] = []
        merged.reserveCapacity(incoming.count + existing.count)
        merged.append(contentsOf: incoming)
        merged.append(contentsOf: existing)

        var seen = Set<String>()
        var unique: [TelegraphItem] = []
        unique.reserveCapacity(merged.count)

        for item in merged {
            if seen.insert(item.uid).inserted {
                unique.append(item)
            }
        }

        unique.sort {
            if $0.ctime != $1.ctime { return $0.ctime > $1.ctime }
            return $0.uid > $1.uid
        }
        if unique.count > cap {
            return Array(unique.prefix(cap))
        }
        return unique
    }

    private nonisolated static func normalizedCursor(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func stabilizedItems(
        from fetched: [TelegraphItem],
        previousItems: [TelegraphItem],
        trigger: RefreshTrigger
    ) -> [TelegraphItem] {
        guard !fetched.isEmpty else { return fetched }
        guard !previousItems.isEmpty else { return fetched }

        var previousByUID: [String: TelegraphItem] = [:]
        previousByUID.reserveCapacity(previousItems.count)
        for item in previousItems {
            previousByUID[item.uid] = item
        }

        var merged: [TelegraphItem] = []
        merged.reserveCapacity(fetched.count)
        for incoming in fetched {
            if let existing = previousByUID[incoming.uid] {
                merged.append(mergedStableItem(existing: existing, incoming: incoming))
            } else {
                merged.append(incoming)
            }
        }

        // Protect the visible page from transient upstream shrink during auto refresh.
        if trigger == .auto, merged.count < max(8, Int(Double(previousItems.count) * 0.35)) {
            return previousItems
        }

        return merged
    }

    private nonisolated static func mergedStableItem(existing: TelegraphItem, incoming: TelegraphItem) -> TelegraphItem {
        let title = preferredText(existing.title, incoming.title, minimum: 2)
        let text = preferredText(existing.text, incoming.text, minimum: 8)
        let sourceName = preferredText(existing.sourceName, incoming.sourceName, minimum: 1)
        let author = preferredText(existing.author, incoming.author, minimum: 1)
        let level = preferredText(existing.level, incoming.level, minimum: 1)
        let url = preferredText(existing.url, incoming.url, minimum: 1)
        let displayTime = preferredText(existing.time, incoming.time, minimum: 1)
        let ctime = max(existing.ctime, incoming.ctime)
        let source = incoming.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existing.source : incoming.source

        return TelegraphItem(
            uid: incoming.uid,
            source: source,
            sourceName: sourceName,
            ctime: ctime,
            time: displayTime,
            title: title,
            text: text,
            author: author,
            level: level,
            url: url
        )
    }

    private nonisolated static func preferredText(_ existing: String, _ incoming: String, minimum: Int) -> String {
        let e = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let i = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return i }
        if i.isEmpty { return e }

        let es = canonicalReadableText(e).count
        let iscore = canonicalReadableText(i).count
        if iscore >= max(es, minimum) {
            return i
        }
        return e
    }

    private nonisolated static func canonicalReadableText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^【[^】]{2,30}】", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^(财联社|新浪财经|华尔街见闻|同花顺|东方财富)(\\d{1,2}月\\d{1,2}日)?电[，,:：\\s]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\u200B\\u200C\\u200D\\u2060\\uFEFF]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func hasMeaningfulCharacter(in text: String) -> Bool {
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

    private func shouldStageIncomingItems(trigger: RefreshTrigger, newItems: [TelegraphItem]) -> Bool {
        guard scope == "home" else { return false }
        guard trigger == .auto else { return false }
        guard hasLoadedSnapshot else { return false }
        guard !items.isEmpty else { return false }
        return !newItems.isEmpty
    }

    private func stageIncomingItems(_ incoming: [TelegraphItem], prepared: PreparedFeedData?) {
        guard !incoming.isEmpty else { return }
        stagedNewItems = Self.mergeIncrementalItems(incoming, onto: stagedNewItems, cap: 120)
        if let prepared {
            stagedPreparedData = prepared
        }
        pendingNewItemsCount = stagedNewItems.count
        refreshState = .stagingPending(pendingNewItemsCount)
    }

    private func clearStagedIncomingItems() {
        stagedNewItems = []
        stagedPreparedData = nil
        pendingNewItemsCount = 0
        if case .stagingPending = refreshState {
            refreshState = .idle
        }
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

    private func reloadCloudSyncedState() {
        let state = persistence.loadState()
        starredUIDs = state.starredUIDs
        readUIDs = state.readUIDs
        laterUIDs = state.laterUIDs
        pinnedUIDs = state.pinnedUIDs
        notifiedUIDs = state.notifiedUIDs
        recomputeDisplayClusters()
        objectWillChange.send()
    }

    private static let refreshTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
