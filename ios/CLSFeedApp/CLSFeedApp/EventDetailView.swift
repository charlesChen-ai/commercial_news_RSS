import SwiftUI

struct EventDetailView: View {
    @ObservedObject var viewModel: FeedViewModel
    @EnvironmentObject private var settings: AppSettings

    let initialCluster: TelegraphCluster

    private var cluster: TelegraphCluster {
        viewModel.clusters.first { $0.id == initialCluster.id || $0.primary.uid == initialCluster.primary.uid } ?? initialCluster
    }

    private var timelineItems: [TelegraphItem] {
        cluster.items.sorted { lhs, rhs in
            if lhs.ctime != rhs.ctime { return lhs.ctime > rhs.ctime }
            return lhs.uid > rhs.uid
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                summaryCard

                TelegraphCardView(
                    item: cluster.primary,
                    quotes: viewModel.quotes(for: cluster),
                    analysis: viewModel.analysisByUID[cluster.primary.uid],
                    isAnalyzing: viewModel.analyzingUIDs.contains(cluster.primary.uid),
                    highlightKeywords: [],
                    isStarred: viewModel.workflowState(for: cluster.primary).isStarred,
                    onToggleStarred: nil,
                    onMarkRead: nil,
                    onMuteSource24h: nil,
                    onMuteSource7d: nil,
                    onAddKeyword: nil,
                    onUncollapse24h: nil,
                    keywordSuggestion: nil,
                    inlineActions: [],
                    onAnalyze: { Task { await viewModel.analyze(item: cluster.primary, settings: settings) } }
                )

                timelineCard
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("事件详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.markRead(uid: cluster.primary.uid)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cluster.primary.displayTitle.isEmpty ? cluster.primary.text : cluster.primary.displayTitle)
                .font(.headline)
                .lineLimit(3)
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Label("\(cluster.mergedCount) 条版本", systemImage: "square.stack.3d.up")
                Text(cluster.sourceNames.joined(separator: " / "))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if let first = timelineItems.last?.time, !first.isEmpty {
                    Text("首发 \(first)")
                }
                if let latest = timelineItems.first?.time, !latest.isEmpty {
                    Text("最新 \(latest)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("事件时间线", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(.blue)

            ForEach(timelineItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(item.time)
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text(item.sourceName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                        Spacer()

                        Button {
                            Task { await viewModel.analyze(item: item, settings: settings) }
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(item.displayTitle.isEmpty ? item.text : item.displayTitle)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)

                    if !item.url.isEmpty, let url = URL(string: item.url) {
                        Link("原文", destination: url)
                            .font(.caption)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}
