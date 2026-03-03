import SwiftUI
#if os(iOS)
import UIKit
#endif

struct FeedView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var errorCenter: AppErrorCenter
    @StateObject private var viewModel = FeedViewModel(scope: "home")
    @State private var showBackToTop = false
    @State private var showRecapSheet = false
    @State private var expandedClusterIDs: Set<String> = []
    @State private var selectedCluster: TelegraphCluster?
    @State private var topSection: FeedTopSection = .headline
    @State private var cachedHeadlineClusters: [TelegraphCluster] = []
    @State private var cachedRealtimeClusters: [TelegraphCluster] = []
    @State private var cachedKeywordHitsByUID: [String: [String]] = [:]
    @State private var cachedKeywordHitCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                TwitterTheme.surface
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topChrome

                    ScrollViewReader { proxy in
                        ScrollView {
                            Color.clear
                                .frame(height: 1)
                                .id("feed_top_anchor")
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: FeedScrollOffsetKey.self,
                                            value: geo.frame(in: .named("feed_scroll")).minY
                                        )
                                    }
                                )

                            LazyVStack(spacing: 0) {
                                if let err = viewModel.feedError, !err.isEmpty {
                                    errorBanner(err)
                                        .padding(.bottom, 8)
                                }

                                if viewModel.pendingAIJobs > 0 {
                                    retryQueueBanner
                                        .padding(.bottom, 8)
                                }

                                if viewModel.displayClusters.isEmpty, !viewModel.isLoading {
                                    emptyCard
                                } else {
                                    topSectionContent
                                }
                            }
                            .padding(.top, 4)
                            .padding(.bottom, 20)
                        }
                        .coordinateSpace(name: "feed_scroll")
                        .onPreferenceChange(FeedScrollOffsetKey.self) { y in
                            let shouldShow = y < -420
                            if shouldShow != showBackToTop {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showBackToTop = shouldShow
                                }
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if showBackToTop {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        proxy.scrollTo("feed_top_anchor", anchor: .top)
                                    }
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 38, height: 38)
                                        .background(Color.black.opacity(0.7), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 16)
                                .padding(.bottom, 18)
                            }
                        }
                        .refreshable {
                            await viewModel.refresh(using: settings)
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 18)
                                .onEnded { value in
                                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                    guard abs(value.translation.width) > 26 else { return }
                                    if value.translation.width < 0 {
                                        switchTopSection(to: .realtime)
                                    } else {
                                        switchTopSection(to: .headline)
                                    }
                                }
                        )
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                // Top-right filter menu was removed; force default feed mode to avoid stale persisted filters.
                viewModel.setFilter(.all)

                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    await viewModel.refresh(using: settings, trigger: .startup)
                }
                recomputeSectionCaches()
            }
            .onDisappear {
                viewModel.stopAutoRefresh()
            }
            .onChange(of: settings.autoRefreshEnabled) { enabled in
                if enabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    viewModel.stopAutoRefresh()
                }
            }
            .onChange(of: settings.refreshInterval) { _ in
                guard settings.autoRefreshEnabled else { return }
                viewModel.startAutoRefresh(using: settings)
            }
            .onChange(of: viewModel.displayClusters) { _ in
                recomputeSectionCaches()
            }
            .onChange(of: settings.keywordSubscriptions) { _ in
                recomputeSectionCaches()
            }
            .onChange(of: viewModel.filter) { _ in
                recomputeSectionCaches()
            }
            .onChange(of: settings.selectedSourceCodes) { _ in
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
                recomputeSectionCaches()
            }
            .onChange(of: settings.serverBaseURL) { _ in
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
                recomputeSectionCaches()
            }
            .onChange(of: settings.offlineModeEnabled) { _ in
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
                recomputeSectionCaches()
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
            .onChange(of: viewModel.feedError) { value in
                if let value, !value.isEmpty {
                    errorCenter.showBanner(
                        title: "信息流刷新异常",
                        message: value,
                        source: "feed.refresh",
                        level: .warning
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
        topSectionSwitcher
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
            switchTopSection(to: section)
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

    @ViewBuilder
    private var topSectionContent: some View {
        Group {
            if topSection == .headline {
                headlineSectionView
                    .id("headline_section")
            } else {
                realtimeSectionView
                    .id("realtime_section")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var headlineSectionView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if headlineClusters.isEmpty {
                Text("当前暂无头条快讯")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
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
        VStack(alignment: .leading, spacing: 0) {
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
                Text("暂无更多实时流内容")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
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

    private func switchTopSection(to next: FeedTopSection) {
        guard next != topSection else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            topSection = next
        }
    }

    private func recomputeSectionCaches() {
        let base = viewModel.displayClusters
        let headlineBase = base
            .filter { ["A", "B"].contains($0.primary.level.uppercased()) }
            .prefix(20)
        cachedHeadlineClusters = Array(headlineBase.prefix(12))

        let keywords = settings.keywordList
        guard !keywords.isEmpty else {
            cachedKeywordHitsByUID = [:]
            cachedKeywordHitCount = 0
            cachedRealtimeClusters = base
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
            cachedRealtimeClusters = base
            normalizeTopSectionIfNeeded()
            return
        }

        let others = base.filter { !hitUIDs.contains($0.primary.uid) }
        cachedRealtimeClusters = matched + others
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

    private func clusterCell(_ cluster: TelegraphCluster, keywordHits: [String], allowEventDetail: Bool) -> some View {
        let showMetaRow = !keywordHits.isEmpty || (allowEventDetail && cluster.isMerged)

        return VStack(spacing: 8) {
            TelegraphCardView(
                item: cluster.primary,
                workflow: viewModel.workflowState(for: cluster.primary),
                quotes: viewModel.quotes(for: cluster),
                analysis: viewModel.analysisByUID[cluster.primary.uid],
                isAnalyzing: viewModel.analyzingUIDs.contains(cluster.primary.uid),
                onAnalyze: {
                    Task { await viewModel.analyze(item: cluster.primary, settings: settings) }
                },
                onTogglePinned: { viewModel.togglePinned(uid: cluster.primary.uid) },
                onToggleStarred: { viewModel.toggleStarred(uid: cluster.primary.uid) },
                onToggleReadLater: { viewModel.toggleReadLater(uid: cluster.primary.uid) },
                onToggleRead: { viewModel.toggleRead(uid: cluster.primary.uid) }
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

                    Spacer()

                    if allowEventDetail, cluster.isMerged {
                        Button {
                            viewModel.markRead(uid: cluster.primary.uid)
                            selectedCluster = cluster
                        } label: {
                            Label("事件详情", systemImage: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
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

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedClusterIDs.contains(cluster.id) {
                        expandedClusterIDs.remove(cluster.id)
                    } else {
                        expandedClusterIDs.insert(cluster.id)
                    }
                }
            } label: {
                Text(expandedClusterIDs.contains(cluster.id) ? "收起版本" : "展开版本")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
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

    private func errorBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let lastAt = viewModel.lastSuccessfulRefreshAt {
                    Text("上次成功：\(lastAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重试") {
                    Task { await viewModel.refresh(using: settings, trigger: .manual) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("暂无快讯")
                .font(.headline)
            Text("下拉刷新或开启自动刷新")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }
}

private struct FeedScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum FeedTopSection {
    case headline
    case realtime
}
