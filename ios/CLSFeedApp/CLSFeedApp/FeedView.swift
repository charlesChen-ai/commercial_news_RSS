import SwiftUI
#if os(iOS)
import UIKit
#endif

struct FeedView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var errorCenter: AppErrorCenter
    let isActive: Bool
    let homeButtonTrigger: Int
    @ObservedObject var viewModel: FeedViewModel
    @State private var showRecapSheet = false
    @State private var expandedClusterIDs: Set<String> = []
    @State private var variantVisibleCountByClusterID: [String: Int] = [:]
    @State private var selectedCluster: TelegraphCluster?
    @State private var topSection: FeedTopSection = .headline
    @State private var cachedHeadlineClusters: [TelegraphCluster] = []
    @State private var cachedRealtimeClusters: [TelegraphCluster] = []
    @State private var cachedKeywordHitsByUID: [String: [String]] = [:]
    @State private var cachedKeywordHitCount = 0
    @State private var readingScrollRequest: FeedScrollRequest?
    @State private var insertedToastCount = 0
    @State private var showInsertedToast = false
    @SceneStorage("feed.home.didBootstrap") private var didBootstrap = false
    @State private var lastHandledHomeButtonTrigger = 0

    init(
        isActive: Bool = true,
        homeButtonTrigger: Int = 0,
        viewModel: FeedViewModel
    ) {
        self.isActive = isActive
        self.homeButtonTrigger = homeButtonTrigger
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TwitterTheme.surface
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topChrome
                    topSectionContent
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: isActive) {
                await handleActivationChange()
            }
            .onChange(of: isActive) { active in
                if !active {
                    viewModel.stopAutoRefresh()
                }
            }
            .onDisappear {
                viewModel.stopAutoRefresh()
            }
            .onChange(of: homeButtonTrigger) { _ in
                guard isActive else { return }
                Task { await handleHomeButtonPressedIfNeeded() }
            }
            .onChange(of: settings.autoRefreshEnabled) { enabled in
                guard isActive else {
                    viewModel.stopAutoRefresh()
                    return
                }
                if enabled {
                    viewModel.startAutoRefresh(using: settings, immediateRefresh: false)
                } else {
                    viewModel.stopAutoRefresh()
                }
            }
            .onChange(of: settings.refreshInterval) { _ in
                guard isActive, settings.autoRefreshEnabled else { return }
                viewModel.startAutoRefresh(using: settings, immediateRefresh: false)
            }
            .onChange(of: viewModel.displayClusters) { _ in
                pruneClusterTransientState()
                recomputeSectionCaches()
            }
            .onChange(of: viewModel.isLoading) { loading in
                guard !loading else { return }
                pruneClusterTransientState()
                recomputeSectionCaches()
            }
            .onChange(of: settings.keywordSubscriptions) { _ in
                _ = viewModel.syncKeywordHitsToFavorites(using: settings)
                recomputeSectionCaches()
            }
            .onChange(of: viewModel.filter) { _ in
                recomputeSectionCaches()
            }
            .onChange(of: settings.selectedSourceCodes) { _ in
                viewModel.invalidateCursor()
                guard isActive else { return }
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings, immediateRefresh: true)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
                recomputeSectionCaches()
            }
            .onChange(of: settings.serverBaseURL) { _ in
                viewModel.invalidateCursor()
                guard isActive else { return }
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings, immediateRefresh: true)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
                recomputeSectionCaches()
            }
            .onChange(of: settings.offlineModeEnabled) { _ in
                viewModel.invalidateCursor()
                guard isActive else { return }
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings, immediateRefresh: true)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
                recomputeSectionCaches()
            }
            .onChange(of: settings.sourceMuteUntilByCode) { _ in
                viewModel.invalidateCursor()
                guard isActive else { return }
                Task { await viewModel.refresh(using: settings, trigger: .manual) }
            }
            .onChange(of: settings.feedCollapseThreshold) { _ in
                Task { await viewModel.applyQualitySettings(using: settings) }
            }
            .onChange(of: settings.feedSourcePriorityByCode) { _ in
                Task { await viewModel.applyQualitySettings(using: settings) }
            }
            .onChange(of: settings.feedUncollapseUIDUntilByUID) { _ in
                Task { await viewModel.applyQualitySettings(using: settings) }
            }
            .onChange(of: settings.aiRetryQueueEnabled) { enabled in
                guard enabled else { return }
                Task { await viewModel.retryQueuedAnalyses(using: settings) }
            }
            .onChange(of: viewModel.aiError) { value in
                if let value, !value.isEmpty {
                    errorCenter.showAlert(
                        title: "AI 分析失败",
                        message: value,
                        source: "feed.ai"
                    )
                }
            }
            .sheet(isPresented: $showRecapSheet) {
                recapSheet
            }
            .sheet(item: $selectedCluster) { cluster in
                NavigationStack {
                    EventDetailView(viewModel: viewModel, initialCluster: cluster)
                        .environmentObject(settings)
                }
            }
        }
    }

    private var retryQueueBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("AI 待重试任务 \(viewModel.pendingAIJobs) 条")
                .font(.footnote.weight(.semibold))
            Spacer(minLength: 8)
            Button("立即重试") {
                Task { await viewModel.retryQueuedAnalyses(using: settings) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TwitterTheme.surface)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(TwitterTheme.divider)
        }
    }

    private var topChrome: some View {
        VStack(spacing: 0) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
                .padding(.top, 6)
                .padding(.bottom, 10)

            topSectionSwitcher
        }
        .background(TwitterTheme.surface)
    }

    private var headlineClusters: [TelegraphCluster] {
        cachedHeadlineClusters
    }

    private var realtimeClusters: [TelegraphCluster] {
        cachedRealtimeClusters
    }

    private var topSectionSwitcher: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                topSectionButton(.headline, title: "头条")
                topSectionButton(.realtime, title: "实时流")
            }
            .padding(.horizontal, 28)
            .padding(.top, 0)

            Divider()
                .overlay(TwitterTheme.divider)
        }
        .background(TwitterTheme.surface)
    }

    private func topSectionButton(_ section: FeedTopSection, title: String) -> some View {
        let selected = topSection == section
        return Button {
            guard topSection != section else { return }
            let started = CFAbsoluteTimeGetCurrent()
            AppHaptics.selection()
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.9, blendDuration: 0.03)) {
                topSection = section
            }
            DispatchQueue.main.async {
                let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                AppTelemetryCenter.shared.record(
                    name: "section_switch",
                    value: ms,
                    meta: ["section": section.rawValue]
                )
            }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(selected ? .bold : .semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(selected ? TwitterTheme.accent : .clear)
                    .frame(width: 84, height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
    }

    private var topSectionContent: some View {
        TabView(selection: $topSection) {
            sectionPage(.headline)
                .tag(FeedTopSection.headline)

            sectionPage(.realtime)
                .tag(FeedTopSection.realtime)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.9, blendDuration: 0.03), value: topSection)
    }

    private func sectionPage(_ section: FeedTopSection) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(sectionTopAnchorID(section))
                    if viewModel.pendingAIJobs > 0 {
                        retryQueueBanner
                            .padding(.bottom, 8)
                    }
                    sectionView(for: section)
                }
                .animation(
                    viewModel.isApplyingPendingInsertion
                        ? .interactiveSpring(response: 0.16, dampingFraction: 0.92, blendDuration: 0.02)
                        : nil,
                    value: sectionIDsSignature(section)
                )
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .refreshable {
                if pendingBadgeCount(for: section) > 0 {
                    let inserted = await applyPendingNewItems(for: section)
                    if inserted > 0 {
                        return
                    }
                }
                await viewModel.refresh(using: settings, trigger: .manual)
            }
            .overlay(alignment: .top) {
                sectionFloatingBanners(section: section)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            .onChange(of: readingScrollRequest) { request in
                guard let request, request.section == section else { return }
                withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.94, blendDuration: 0.01)) {
                    proxy.scrollTo(request.clusterID, anchor: .top)
                }
                readingScrollRequest = nil
            }
        }
    }

    @ViewBuilder
    private func sectionFloatingBanners(section: FeedTopSection) -> some View {
        let pendingCount = pendingBadgeCount(for: section)
        VStack(spacing: 8) {
            if pendingCount > 0 {
                Button {
                    AppHaptics.selection()
                    Task {
                        _ = await applyPendingNewItems(for: section)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                        Text("新消息 \(pendingCount) 条")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(TwitterTheme.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
            }

            if showInsertedToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("已更新 \(insertedToastCount) 条")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.72), in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @MainActor
    private func applyPendingNewItems(for section: FeedTopSection) async -> Int {
        readingScrollRequest = FeedScrollRequest(
            section: section,
            clusterID: sectionTopAnchorID(section)
        )
        let inserted = await viewModel.applyPendingNewItems(using: settings)
        recomputeSectionCaches()
        readingScrollRequest = FeedScrollRequest(
            section: section,
            clusterID: sectionTopAnchorID(section)
        )
        guard inserted > 0 else { return 0 }
        insertedToastCount = inserted
        showInsertedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) {
            withAnimation(.easeOut(duration: 0.18)) {
                showInsertedToast = false
            }
        }
        AppHaptics.impact()
        return inserted
    }

    @ViewBuilder
    private func sectionView(for section: FeedTopSection) -> some View {
        if section == .headline {
            headlineSectionView
        } else {
            realtimeSectionView
        }
    }

    private var headlineSectionView: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if headlineClusters.isEmpty {
                if viewModel.isLoading {
                    skeletonSectionView
                } else {
                    Text("当前暂无头条快讯")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                }
            } else {
                ForEach(headlineClusters) { cluster in
                    clusterCell(
                        cluster,
                        keywordHits: cachedKeywordHitsByUID[cluster.primary.uid] ?? [],
                        allowEventDetail: false
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var realtimeSectionView: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if cachedKeywordHitCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.orange)
                    Text("关注命中 \(cachedKeywordHitCount) 条，已优先置顶")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Divider().overlay(TwitterTheme.divider)
                }
            }

            if realtimeClusters.isEmpty {
                if viewModel.isLoading {
                    skeletonSectionView
                } else {
                    Text("暂无更多实时流内容")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                }
            } else {
                ForEach(realtimeClusters) { cluster in
                    clusterCell(
                        cluster,
                        keywordHits: cachedKeywordHitsByUID[cluster.primary.uid] ?? [],
                        allowEventDetail: true
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skeletonSectionView: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                FeedSkeletonCard()
                    .overlay(alignment: .bottom) {
                        Divider().overlay(TwitterTheme.divider)
                    }
            }
        }
    }

    private func recomputeSectionCaches() {
        let base = viewModel.displayClusters
        let headlineBase = base
            .filter { ["A", "B"].contains($0.primary.level.uppercased()) }
            .prefix(20)
        let nextHeadline = Array(headlineBase.prefix(12))
        if !nextHeadline.isEmpty || !viewModel.isLoading {
            cachedHeadlineClusters = nextHeadline
        }

        let keywords = settings.keywordList
        guard !keywords.isEmpty else {
            cachedKeywordHitsByUID = [:]
            cachedKeywordHitCount = 0
            if !base.isEmpty || !viewModel.isLoading {
                cachedRealtimeClusters = base
            }
            normalizeTopSectionIfNeeded()
            return
        }

        var hitMap: [String: [String]] = [:]
        var hitUIDs = Set<String>()

        for cluster in base {
            let hits = matchedKeywords(for: cluster, keywords: keywords)
            if !hits.isEmpty {
                hitMap[cluster.primary.uid] = hits
                hitUIDs.insert(cluster.primary.uid)
            }
        }

        cachedKeywordHitsByUID = hitMap
        let matched = base.filter { hitUIDs.contains($0.primary.uid) }
        cachedKeywordHitCount = matched.count
        if matched.isEmpty {
            if !base.isEmpty || !viewModel.isLoading {
                cachedRealtimeClusters = base
            }
            normalizeTopSectionIfNeeded()
            return
        }

        let others = base.filter { !hitUIDs.contains($0.primary.uid) }
        let nextRealtime = matched + others
        if !nextRealtime.isEmpty || !viewModel.isLoading {
            cachedRealtimeClusters = nextRealtime
        }
        normalizeTopSectionIfNeeded()
    }

    private func normalizeTopSectionIfNeeded() {
        if topSection == .headline, cachedHeadlineClusters.isEmpty, !cachedRealtimeClusters.isEmpty {
            topSection = .realtime
            return
        }

        if topSection == .realtime, cachedRealtimeClusters.isEmpty, !cachedHeadlineClusters.isEmpty {
            topSection = .headline
        }
    }

    private func matchedKeywords(for cluster: TelegraphCluster, keywords: [String]) -> [String] {
        if keywords.isEmpty { return [] }
        let haystack = cluster.items.map { "\($0.title) \($0.text)" }.joined(separator: " ").lowercased()
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

    private func clusterCell(
        _ cluster: TelegraphCluster,
        keywordHits: [String],
        allowEventDetail: Bool
    ) -> some View {
        let showMetaRow = !keywordHits.isEmpty
        let workflow = viewModel.workflowState(for: cluster.primary)
        let keywordSuggestion = suggestedKeyword(for: cluster.primary)
        let inlineActions = cardInlineActions(for: cluster, allowEventDetail: allowEventDetail)

        return VStack(spacing: 10) {
            TelegraphCardView(
                item: cluster.primary,
                quotes: viewModel.quotes(for: cluster),
                analysis: viewModel.analysisByUID[cluster.primary.uid],
                isAnalyzing: viewModel.analyzingUIDs.contains(cluster.primary.uid),
                highlightKeywords: keywordHits,
                isStarred: workflow.isStarred,
                onToggleStarred: {
                    viewModel.toggleStarred(uid: cluster.primary.uid)
                    AppHaptics.impact()
                },
                onMarkRead: {
                    viewModel.markRead(uid: cluster.primary.uid)
                    AppHaptics.impact()
                },
                onMuteSource24h: {
                    applySourceMute(sourceCode: cluster.primary.source, duration: 24 * 3600)
                },
                onMuteSource7d: {
                    applySourceMute(sourceCode: cluster.primary.source, duration: 7 * 24 * 3600)
                },
                onAddKeyword: {
                    guard !keywordSuggestion.isEmpty else { return }
                    _ = settings.addKeywordSubscription(keywordSuggestion)
                    AppHaptics.impact()
                },
                keywordSuggestion: keywordSuggestion,
                inlineActions: inlineActions,
                onAnalyze: {
                    Task { await viewModel.analyze(item: cluster.primary, settings: settings) }
                }
            )

            if showMetaRow {
                HStack(spacing: 6) {
                    if !keywordHits.isEmpty {
                        ForEach(keywordHits, id: \.self) { keyword in
                            Text("#\(keyword)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }

            if cluster.isMerged {
                clusterFooter(cluster)
            }

            if expandedClusterIDs.contains(cluster.id), !cluster.variants.isEmpty {
                VStack(spacing: 6) {
                    ForEach(cluster.variants) { item in
                        variantRow(item)
                    }
                }
                .padding(10)
                .background(
                    Color(uiColor: .tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
        }
        .id(cluster.id)
        .transition(
            .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .opacity
            )
        )
        .background(TwitterTheme.surface)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(TwitterTheme.divider)
        }
    }

    private func clusterFooter(_ cluster: TelegraphCluster) -> some View {
        HStack(spacing: 8) {
            Label("同事件 \(cluster.mergedCount) 条", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(cluster.sourceNames.joined(separator: " / "))
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
    }

    private func cardInlineActions(for cluster: TelegraphCluster, allowEventDetail: Bool) -> [TelegraphInlineAction] {
        guard cluster.isMerged else { return [] }
        var out: [TelegraphInlineAction] = []

        if allowEventDetail {
            out.append(
                TelegraphInlineAction(
                    id: "detail-\(cluster.id)",
                    title: "事件详情",
                    icon: "chevron.right"
                ) {
                    viewModel.markRead(uid: cluster.primary.uid)
                    selectedCluster = cluster
                    AppHaptics.selection()
                }
            )
        }

        let expanded = expandedClusterIDs.contains(cluster.id)
        out.append(
            TelegraphInlineAction(
                id: "expand-\(cluster.id)",
                title: expanded ? "收起版本" : "展开版本",
                icon: expanded ? "chevron.up" : "chevron.down",
                isActive: expanded
            ) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expandedClusterIDs.contains(cluster.id) {
                        expandedClusterIDs.remove(cluster.id)
                    } else {
                        expandedClusterIDs.insert(cluster.id)
                    }
                }
                AppHaptics.selection()
            }
        )

        return out
    }

    private func variantRow(_ item: TelegraphItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.sourceName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.displayTitle.isEmpty ? item.text : item.displayTitle)
                    .font(.footnote)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 8)

            Button {
                Task { await viewModel.analyze(item: item, settings: settings) }
            } label: {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .padding(6)
                    .background(Color.blue.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var recapSheet: some View {
        NavigationStack {
            ScrollView {
                Text(recapDisplayText)
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .padding(12)
            }
            .navigationTitle("今日复盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { showRecapSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button("刷新") {
                            _ = viewModel.generateTodayRecap(force: true)
                        }
                        Button("复制") {
#if os(iOS)
                            UIPasteboard.general.string = viewModel.latestRecapText
#endif
                        }
                    }
                }
            }
        }
    }

    private var recapDisplayText: String {
        if !viewModel.latestRecapText.isEmpty {
            return viewModel.latestRecapText
        }
        if let cached = viewModel.recapCachedForToday(), !cached.isEmpty {
            return cached
        }
        return "暂无复盘内容，点击右上角“刷新”生成。"
    }

    @MainActor
    private func handleActivationChange() async {
        guard isActive else {
            viewModel.stopAutoRefresh()
            return
        }

        let firstActivation = !didBootstrap
        if firstActivation {
            didBootstrap = true
            viewModel.setFilter(.all)
            _ = viewModel.syncKeywordHitsToFavorites(using: settings)
        }

        if settings.autoRefreshEnabled {
            viewModel.startAutoRefresh(using: settings, immediateRefresh: firstActivation)
        } else if firstActivation {
            await viewModel.refresh(using: settings, trigger: .startup)
        }
        recomputeSectionCaches()

        if homeButtonTrigger != lastHandledHomeButtonTrigger {
            await handleHomeButtonPressedIfNeeded()
        }
    }

    @MainActor
    private func handleHomeButtonPressedIfNeeded() async {
        guard homeButtonTrigger != lastHandledHomeButtonTrigger else { return }
        lastHandledHomeButtonTrigger = homeButtonTrigger
        let started = CFAbsoluteTimeGetCurrent()

        let currentSection = topSection
        if let topClusterID = sectionClusters(currentSection).first?.id {
            readingScrollRequest = FeedScrollRequest(section: currentSection, clusterID: topClusterID)
        }

        await viewModel.refresh(using: settings, trigger: .manual)
        recomputeSectionCaches()
        AppTelemetryCenter.shared.record(
            name: "home_button_refresh",
            value: (CFAbsoluteTimeGetCurrent() - started) * 1000,
            meta: ["section": currentSection.rawValue]
        )
    }

    private func applySourceMute(sourceCode: String, duration: TimeInterval) {
        guard let source = NewsSource(rawValue: sourceCode) else { return }
        settings.muteSource(source, duration: duration)
        AppHaptics.impact()
        viewModel.invalidateCursor()
        Task { await viewModel.refresh(using: settings, trigger: .manual) }
    }

    private func suggestedKeyword(for item: TelegraphItem) -> String {
        let preferred = item.displayTitle.isEmpty ? item.text : item.displayTitle
        let separators = CharacterSet(charactersIn: "，,。；;：:、!！?？()（）【】[]\n\t ")
        let parts = preferred
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }

        if let first = parts.first {
            return String(first.prefix(12))
        }
        return ""
    }

    private func sectionClusters(_ section: FeedTopSection) -> [TelegraphCluster] {
        section == .headline ? headlineClusters : realtimeClusters
    }

    private func pendingBadgeCount(for section: FeedTopSection) -> Int {
        switch section {
        case .headline:
            return viewModel.pendingHeadlineNewItemsCount
        case .realtime:
            return viewModel.pendingNewItemsCount
        }
    }

    private func sectionIDsSignature(_ section: FeedTopSection) -> String {
        let ids = sectionClusters(section).prefix(80).map(\.id).joined(separator: "|")
        return "\(section.rawValue)|\(ids)"
    }

    private func sectionTopAnchorID(_ section: FeedTopSection) -> String {
        "feed.top.anchor.\(section.rawValue)"
    }
}

private enum FeedTopSection: String, CaseIterable {
    case headline
    case realtime
}

private struct FeedScrollRequest: Equatable {
    let section: FeedTopSection
    let clusterID: String
}

private struct FeedSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 68, height: 11)
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 58, height: 11)
            }

            RoundedRectangle(cornerRadius: 5)
                .fill(Color.black.opacity(0.09))
                .frame(height: 16)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.black.opacity(0.06))
                .frame(height: 14)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.black.opacity(0.06))
                .frame(width: 220, height: 14)

            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.06))
                    .frame(width: 90, height: 28)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }
}
