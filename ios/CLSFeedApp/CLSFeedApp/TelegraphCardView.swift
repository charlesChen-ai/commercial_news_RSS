import SwiftUI

struct TelegraphInlineAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    init(
        id: String,
        title: String,
        icon: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isActive = isActive
        self.action = action
    }
}

struct TelegraphCardView: View {
    let item: TelegraphItem
    let quotes: [StockQuote]
    let analysis: AIAnalysis?
    let isAnalyzing: Bool
    let highlightKeywords: [String]
    let isStarred: Bool
    let onToggleStarred: (() -> Void)?
    let onMarkRead: (() -> Void)?
    let onMuteSource24h: (() -> Void)?
    let onMuteSource7d: (() -> Void)?
    let onAddKeyword: (() -> Void)?
    let keywordSuggestion: String?
    let inlineActions: [TelegraphInlineAction]
    let onAnalyze: () -> Void

    @State private var expandText = false
    private static var highlightCache: [String: AttributedString] = [:]
    private static let highlightCacheQueue = DispatchQueue(label: "cls.telegraph.highlight.cache")
    private static let highlightCacheLimit = 3200

    private var cleanTitle: String {
        item.displayTitle
    }

    private var cleanText: String {
        item.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTitle: Bool {
        !cleanTitle.isEmpty
    }

    private var normalizedHighlightKeywords: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for keyword in highlightKeywords {
            let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.count < 2 { continue }
            if seen.insert(normalized).inserted {
                out.append(normalized)
            }
            if out.count >= 6 {
                break
            }
        }
        return out
    }

    private var analyzeForegroundColor: Color {
        TwitterTheme.accent
    }

    private var analyzeBackgroundColor: Color {
        analysis == nil ? TwitterTheme.accent.opacity(0.12) : TwitterTheme.accent.opacity(0.18)
    }

    private var analyzeBorderColor: Color {
        analysis == nil ? TwitterTheme.accent.opacity(0.22) : TwitterTheme.accent.opacity(0.30)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            contentBlock
            expandButton
            quoteStrip
            actionRow

            if let analysis {
                analysisPanel(analysis)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TwitterTheme.surface)
        .contextMenu {
            if let onToggleStarred {
                Button(isStarred ? "取消收藏" : "收藏", systemImage: isStarred ? "star.slash" : "star") {
                    onToggleStarred()
                }
            }
            if let onMarkRead {
                Button("标记已读", systemImage: "checkmark.circle") {
                    onMarkRead()
                }
            }
            if let onMuteSource24h {
                Button("屏蔽来源 24 小时", systemImage: "speaker.slash") {
                    onMuteSource24h()
                }
            }
            if let onMuteSource7d {
                Button("屏蔽来源 7 天", systemImage: "speaker.slash.fill") {
                    onMuteSource7d()
                }
            }
            if let onAddKeyword {
                let suggestion = keywordSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if suggestion.isEmpty {
                    Button("加入关键词", systemImage: "plus.circle") {
                        onAddKeyword()
                    }
                } else {
                    Button("加入关键词：\(suggestion)", systemImage: "plus.circle") {
                        onAddKeyword()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(item.time)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)

            Spacer()

            Text(item.sourceName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TwitterTheme.accent)
        }
    }

    @ViewBuilder
    private var contentBlock: some View {
        if hasTitle {
            Text(highlighted(cleanTitle, baseColor: .primary, cacheToken: "title.primary"))
                .font(.headline)
                .lineSpacing(2)

            if !cleanText.isEmpty {
                Text(highlighted(cleanText, baseColor: .secondary, cacheToken: "text.secondary"))
                    .font(.subheadline)
                    .lineLimit(expandText ? nil : 4)
            }
        } else if !cleanText.isEmpty {
            Text(highlighted(cleanText, baseColor: .primary, cacheToken: "text.primary"))
                .font(.headline)
                .lineSpacing(2)
                .lineLimit(expandText ? nil : 5)
        } else {
            Text("（内容获取中）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var expandButton: some View {
        if cleanText.count > 120 {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    expandText.toggle()
                }
            } label: {
                Label(expandText ? "收起全文" : "展开全文", systemImage: expandText ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TwitterTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var quoteStrip: some View {
        if !quotes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(quotes.prefix(3))) { quote in
                        HStack(spacing: 4) {
                            Text(quote.name)
                                .lineLimit(1)
                            Text("\(String(format: "%.2f", quote.price))")
                                .monospacedDigit()
                            Text(quote.changeText)
                                .monospacedDigit()
                                .foregroundStyle(quote.changePercent >= 0 ? .red : .green)
                        }
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(TwitterTheme.subtle, in: Capsule())
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if !inlineActions.isEmpty {
                HStack(spacing: 14) {
                    ForEach(inlineActions) { action in
                        Button {
                            action.action()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: action.icon)
                                    .font(.caption2.weight(.semibold))
                                Text(action.title)
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(action.isActive ? TwitterTheme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                onAnalyze()
            } label: {
                HStack(spacing: 6) {
                    if isAnalyzing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(analyzeForegroundColor)
                    } else {
                        Image(systemName: analysis == nil ? "sparkles" : "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                    }
                    Text(isAnalyzing ? "分析中" : (analysis == nil ? "AI 分析" : "重分析"))
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(analyzeForegroundColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(analyzeBackgroundColor, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(analyzeBorderColor, lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .disabled(isAnalyzing)
            .opacity(isAnalyzing ? 0.78 : 1)
        }
    }

    private func analysisPanel(_ analysis: AIAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(analysis.sentimentText)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(sentimentColor(analysis).opacity(0.16), in: Capsule())
                    .foregroundStyle(sentimentColor(analysis))

                Text("分值 \(analysis.score)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.05), in: Capsule())

                Text("置信 \(Int((analysis.confidence * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                if let model = analysis.model, !model.isEmpty {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            scoreBar(score: analysis.score, tint: sentimentColor(analysis))

            if !analysis.summary.isEmpty {
                Text(analysis.summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if !analysis.actionSummary.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("交易结论", systemImage: "target")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text(analysis.actionSummary)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }

            if !analysis.tradeIdeas.isEmpty {
                factorsSection(title: "可执行方向", items: analysis.tradeIdeas, tint: .blue, icon: "bolt.fill")
            }

            if !analysis.riskAlerts.isEmpty {
                factorsSection(title: "风险提示", items: analysis.riskAlerts, tint: .orange, icon: "exclamationmark.triangle.fill")
            }

            if !analysis.bullishTargets.isEmpty {
                tagsSection(title: "偏利好方向", icon: "arrow.up.right.circle.fill", items: analysis.bullishTargets, tint: .green)
            }

            if !analysis.bearishTargets.isEmpty {
                tagsSection(title: "偏利空方向", icon: "arrow.down.right.circle.fill", items: analysis.bearishTargets, tint: .red)
            }

            if !analysis.impactTargets.isEmpty {
                tagsSection(title: "影响标的", icon: "scope", items: analysis.impactTargets, tint: .blue)
            }

            if !analysis.positiveFactors.isEmpty || !analysis.negativeFactors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !analysis.positiveFactors.isEmpty {
                        factorsSection(title: "利好因子", items: analysis.positiveFactors, tint: .green, icon: "plus.circle.fill")
                    }
                    if !analysis.negativeFactors.isEmpty {
                        factorsSection(title: "风险因子", items: analysis.negativeFactors, tint: .red, icon: "minus.circle.fill")
                    }
                }
            }
        }
        .padding(10)
        .background(TwitterTheme.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TwitterTheme.divider, lineWidth: 1)
        )
    }

    private func scoreBar(score: Int, tint: Color) -> some View {
        GeometryReader { proxy in
            let progress = max(0, min(1, Double(score + 100) / 200.0))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.07))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.55), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 7)
    }

    private func tagsSection(title: String, icon: String, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func factorsSection(title: String, items: [String], tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, text in
                Text("• \(text)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sentimentColor(_ analysis: AIAnalysis) -> Color {
        switch analysis.sentiment.lowercased() {
        case "bullish", "positive":
            return .green
        case "bearish", "negative":
            return .red
        default:
            return .orange
        }
    }

    private func highlighted(_ text: String, baseColor: Color, cacheToken: String) -> AttributedString {
        let keywords = normalizedHighlightKeywords
        let cacheKey = "\(cacheToken)|\(keywords.joined(separator: "|"))|\(text.hashValue)"
        if let cached = Self.cachedHighlight(cacheKey) {
            return cached
        }

        var output = AttributedString(text)
        output.foregroundColor = baseColor
        guard !keywords.isEmpty else { return output }

        let lowered = text.lowercased()
        for keyword in keywords.sorted(by: { $0.count > $1.count }) {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let found = lowered.range(of: keyword, options: [], range: searchRange) {
                if let attrRange = Range(found, in: output) {
                    output[attrRange].foregroundColor = .orange
                    output[attrRange].backgroundColor = Color.orange.opacity(0.16)
                }
                searchRange = found.upperBound..<lowered.endIndex
            }
        }

        Self.storeHighlight(output, key: cacheKey)
        return output
    }

    private static func cachedHighlight(_ key: String) -> AttributedString? {
        highlightCacheQueue.sync {
            highlightCache[key]
        }
    }

    private static func storeHighlight(_ value: AttributedString, key: String) {
        highlightCacheQueue.sync {
            if highlightCache.count > highlightCacheLimit {
                highlightCache.removeAll(keepingCapacity: true)
            }
            highlightCache[key] = value
        }
    }
}
