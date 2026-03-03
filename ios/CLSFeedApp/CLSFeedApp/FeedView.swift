import SwiftUI
#if os(iOS)
import UIKit
#endif

struct FeedView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = FeedViewModel()
    @State private var showErrorAlert = false
    @State private var showBackToTop = false
    @State private var showRecapSheet = false
    @State private var expandedClusterIDs: Set<String> = []
    @State private var selectedCluster: TelegraphCluster?
    @State private var topSection: FeedTopSection = .headline

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

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

                        LazyVStack(spacing: 14) {
                            if let err = viewModel.lastError, !err.isEmpty {
                                errorBanner(err)
                            }

                            topSectionSwitcher

                            if viewModel.displayClusters.isEmpty, !viewModel.isLoading {
                                emptyCard
                            } else {
                                if topSection == .headline {
                                    sectionCard(
                                        title: "头条",
                                        subtitle: "A/B级高优先快讯",
                                        icon: "flame.fill",
                                        tint: .red
                                    ) {
                                        if headlineClusters.isEmpty {
                                            Text("当前暂无头条")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .padding(.vertical, 4)
                                        } else {
                                            ForEach(headlineClusters) { cluster in
                                                clusterCell(cluster, keywordHits: matchedKeywords(for: cluster, keywords: settings.keywordList))
                                            }
                                        }
                                    }
                                } else {
                                    sectionCard(
                                        title: "实时流",
                                        subtitle: "按时间持续更新",
                                        icon: "bolt.horizontal.fill",
                                        tint: .blue
                                    ) {
                                        if !keywordHitClusters.isEmpty {
                                            HStack(spacing: 8) {
                                                Image(systemName: "bell.badge.fill")
                                                    .foregroundStyle(.orange)
                                                Text("关注命中 \(keywordHitClusters.count) 条，已优先置顶")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                            }
                                        }

                                        if realtimeClusters.isEmpty {
                                            Text("暂无更多实时流内容")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .padding(.vertical, 4)
                                        } else {
                                            ForEach(realtimeClusters) { cluster in
                                                clusterCell(cluster, keywordHits: matchedKeywords(for: cluster, keywords: settings.keywordList))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 10)
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
                        DragGesture(minimumDistance: 28)
                            .onEnded { value in
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                guard abs(value.translation.width) > 56 else { return }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if value.translation.width < 0 {
                                        topSection = .realtime
                                    } else {
                                        topSection = .headline
                                    }
                                }
                            }
                    )
                }
            }
            .navigationTitle("快讯信息流")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("筛选", selection: Binding(
                            get: { viewModel.filter },
                            set: { viewModel.setFilter($0) }
                        )) {
                            ForEach(FeedFilterOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }

                        Button("今日复盘") {
                            _ = viewModel.generateTodayRecap(force: false)
                            showRecapSheet = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(viewModel.filter.displayName)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        settings.autoRefreshEnabled.toggle()
                    } label: {
                        Image(systemName: settings.autoRefreshEnabled ? "bolt.circle.fill" : "bolt.slash.circle")
                            .foregroundStyle(settings.autoRefreshEnabled ? .blue : .secondary)
                    }
                    .accessibilityLabel(settings.autoRefreshEnabled ? "关闭自动刷新" : "开启自动刷新")
                }
            }
            .task {
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    await viewModel.refresh(using: settings)
                }
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
            .onChange(of: settings.selectedSourceCodes) { _ in
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
            }
            .onChange(of: settings.serverBaseURL) { _ in
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
            }
            .onChange(of: viewModel.lastError) { value in
                if let value, !value.isEmpty {
                    showErrorAlert = true
                }
            }
            .alert("AI 分析失败", isPresented: $showErrorAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.lastError ?? "未知错误")
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

    private var headlineClusters: [TelegraphCluster] {
        Array(
            viewModel.displayClusters
                .filter { ["A", "B"].contains($0.primary.level.uppercased()) }
                .prefix(12)
        )
    }

    private var keywordHitClusters: [TelegraphCluster] {
        let keywords = settings.keywordList
        if keywords.isEmpty { return [] }

        let headlineUIDs = Set(headlineClusters.map(\.primary.uid))
        return viewModel.displayClusters.filter { cluster in
            !headlineUIDs.contains(cluster.primary.uid) && !matchedKeywords(for: cluster, keywords: keywords).isEmpty
        }
    }

    private var realtimeClusters: [TelegraphCluster] {
        let headlineUIDs = Set(headlineClusters.map(\.primary.uid))
        let base = viewModel.displayClusters.filter { !headlineUIDs.contains($0.primary.uid) }
        let keywordUIDs = Set(keywordHitClusters.map(\.primary.uid))
        let matched = base.filter { keywordUIDs.contains($0.primary.uid) }
        let others = base.filter { !keywordUIDs.contains($0.primary.uid) }
        return matched + others
    }

    private var topSectionSwitcher: some View {
        HStack(spacing: 10) {
            topSectionButton(.headline, title: "头条", icon: "flame.fill")
            topSectionButton(.realtime, title: "实时流", icon: "bolt.horizontal.fill")
            Spacer(minLength: 8)
            Text("左右滑动切换")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }

    private func topSectionButton(_ section: FeedTopSection, title: String, icon: String) -> some View {
        let selected = topSection == section
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                topSection = section
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    selected ? Color.blue : Color(uiColor: .secondarySystemBackground),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(Color.black.opacity(selected ? 0 : 0.08), lineWidth: selected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
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

    private func sectionCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            content()
        }
        .padding(.horizontal, 12)
    }

    private func clusterCell(_ cluster: TelegraphCluster, keywordHits: [String]) -> some View {
        VStack(spacing: 8) {
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
            .padding(.horizontal, 4)

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
        Text(text)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
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
