import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var errorCenter: AppErrorCenter
    let isActive: Bool
    @ObservedObject var viewModel: FeedViewModel
    @SceneStorage("feed.favorites.didBootstrap") private var didBootstrap = false
    @State private var keywordHitsByUID: [String: [String]] = [:]

    init(isActive: Bool = true, viewModel: FeedViewModel) {
        self.isActive = isActive
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TwitterTheme.surface
                    .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if case .loading(let trigger) = viewModel.refreshState {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("\(trigger.displayText)中")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                Divider().overlay(TwitterTheme.divider)
                            }
                        }

                        if viewModel.displayClusters.isEmpty, !viewModel.isLoading {
                            VStack(spacing: 8) {
                                Image(systemName: "star")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("还没有收藏内容")
                                    .font(.headline)
                                Text("命中订阅关键词的快讯会自动进入这里")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                        } else {
                            ForEach(viewModel.displayClusters) { cluster in
                                let hits = keywordHitsByUID[cluster.primary.uid] ?? []
                                let workflow = viewModel.workflowState(for: cluster.primary)
                                let keywordSuggestion = suggestedKeyword(for: cluster.primary)
                                TelegraphCardView(
                                    item: cluster.primary,
                                    quotes: viewModel.quotes(for: cluster),
                                    analysis: viewModel.analysisByUID[cluster.primary.uid],
                                    isAnalyzing: viewModel.analyzingUIDs.contains(cluster.primary.uid),
                                    highlightKeywords: hits,
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
                                    inlineActions: [],
                                    onAnalyze: {
                                        Task { await viewModel.analyze(item: cluster.primary, settings: settings) }
                                    }
                                )
                                .overlay(alignment: .bottom) {
                                    Divider().overlay(TwitterTheme.divider)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .refreshable {
                    await viewModel.refresh(using: settings)
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
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
            .onChange(of: settings.selectedSourceCodes) { _ in
                guard isActive else { return }
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings, immediateRefresh: true)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
            }
            .onChange(of: settings.serverBaseURL) { _ in
                guard isActive else { return }
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings, immediateRefresh: true)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
            }
            .onChange(of: settings.offlineModeEnabled) { _ in
                guard isActive else { return }
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings, immediateRefresh: true)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
            }
            .onChange(of: settings.keywordSubscriptions) { _ in
                _ = viewModel.syncKeywordHitsToFavorites(using: settings)
                recomputeKeywordHitsCache()
            }
            .onChange(of: viewModel.displayClusters) { _ in
                recomputeKeywordHitsCache()
            }
            .onChange(of: viewModel.isLoading) { loading in
                guard !loading else { return }
                recomputeKeywordHitsCache()
            }
            .onChange(of: settings.sourceMuteUntilByCode) { _ in
                guard isActive else { return }
                Task { await viewModel.refresh(using: settings, trigger: .manual) }
            }
            .onChange(of: settings.feedCollapseThreshold) { _ in
                Task { await viewModel.applyQualitySettings(using: settings) }
            }
            .onChange(of: settings.feedSourcePriorityByCode) { _ in
                Task { await viewModel.applyQualitySettings(using: settings) }
            }
            .onChange(of: viewModel.aiError) { value in
                if let value, !value.isEmpty {
                    errorCenter.showAlert(
                        title: "AI 分析失败",
                        message: value,
                        source: "favorites.ai"
                    )
                }
            }
        }
    }

    private func matchedKeywords(for item: TelegraphItem) -> [String] {
        let keywords = settings.keywordList
        guard !keywords.isEmpty else { return [] }
        let haystack = "\(item.title) \(item.text)".lowercased()
        var out: [String] = []
        for keyword in keywords {
            if haystack.contains(keyword) {
                out.append(keyword)
            }
            if out.count >= 3 {
                break
            }
        }
        return out
    }

    private func recomputeKeywordHitsCache() {
        let keywords = settings.keywordList
        guard !keywords.isEmpty else {
            keywordHitsByUID = [:]
            return
        }

        var map: [String: [String]] = [:]
        for cluster in viewModel.displayClusters {
            let hits = matchedKeywords(for: cluster.primary)
            if !hits.isEmpty {
                map[cluster.primary.uid] = hits
            }
        }
        keywordHitsByUID = map
    }

    private func applySourceMute(sourceCode: String, duration: TimeInterval) {
        guard let source = NewsSource(rawValue: sourceCode) else { return }
        settings.muteSource(source, duration: duration)
        AppHaptics.impact()
        Task { await viewModel.refresh(using: settings, trigger: .manual) }
    }

    private func suggestedKeyword(for item: TelegraphItem) -> String {
        let preferred = item.displayTitle.isEmpty ? item.text : item.displayTitle
        let separators = CharacterSet(charactersIn: "，,。；;：:、!！?？()（）【】[]\n\t ")
        let parts = preferred
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        guard let first = parts.first else { return "" }
        return String(first.prefix(12))
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
            viewModel.setFilter(.starred)
            _ = viewModel.syncKeywordHitsToFavorites(using: settings)
            recomputeKeywordHitsCache()
        }

        if settings.autoRefreshEnabled {
            viewModel.startAutoRefresh(using: settings, immediateRefresh: firstActivation)
        } else if firstActivation {
            await viewModel.refresh(using: settings, trigger: .startup)
        }
        recomputeKeywordHitsCache()
    }
}
