import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var errorCenter: AppErrorCenter
    @StateObject private var viewModel = FeedViewModel(scope: "favorites")

    var body: some View {
        NavigationStack {
            ZStack {
                TwitterTheme.surface
                    .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        header

                        if let err = viewModel.feedError, !err.isEmpty {
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                                Text("在首页点击星标后会出现在这里")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                        } else {
                            ForEach(viewModel.displayClusters) { cluster in
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
            .task {
                viewModel.setFilter(.starred)
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    await viewModel.refresh(using: settings, trigger: .startup)
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
            .onChange(of: settings.offlineModeEnabled) { _ in
                if settings.autoRefreshEnabled {
                    viewModel.startAutoRefresh(using: settings)
                } else {
                    Task { await viewModel.refresh(using: settings) }
                }
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
            .onChange(of: viewModel.feedError) { value in
                if let value, !value.isEmpty {
                    errorCenter.showBanner(
                        title: "收藏页刷新异常",
                        message: value,
                        source: "favorites.refresh",
                        level: .warning
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .foregroundStyle(TwitterTheme.accent)
            Text("已收藏快讯")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().overlay(TwitterTheme.divider)
        }
    }
}
