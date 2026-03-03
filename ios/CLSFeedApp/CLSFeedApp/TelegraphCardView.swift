import SwiftUI

struct TelegraphCardView: View {
    let item: TelegraphItem
    let workflow: TelegraphWorkflowState
    let quotes: [StockQuote]
    let analysis: AIAnalysis?
    let isAnalyzing: Bool
    let onAnalyze: () -> Void
    let onTogglePinned: () -> Void
    let onToggleStarred: () -> Void
    let onToggleReadLater: () -> Void
    let onToggleRead: () -> Void

    @State private var expandText = false

    private var cleanTitle: String {
        item.displayTitle
    }

    private var cleanText: String {
        item.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTitle: Bool {
        !cleanTitle.isEmpty
    }

    private var analyzeForegroundColor: Color {
        Color.blue.opacity(0.86)
    }

    private var analyzeBackgroundColor: Color {
        analysis == nil ? Color.blue.opacity(0.14) : Color.blue.opacity(0.2)
    }

    private var analyzeBorderColor: Color {
        analysis == nil ? Color.blue.opacity(0.25) : Color.blue.opacity(0.32)
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
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(workflow.isPinned ? 0.22 : 0.14), lineWidth: workflow.isPinned ? 1.5 : 1.2)
        )
        .overlay(alignment: .leading) {
            if let sideAccentColor {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(sideAccentColor)
                    .frame(width: 3.5)
                    .padding(.vertical, 9)
            }
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .opacity(workflow.isRead ? 0.95 : 1)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.12), in: Capsule())
                .foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private var contentBlock: some View {
        if hasTitle {
            Text(cleanTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .onTapGesture {
                    if !workflow.isRead {
                        onToggleRead()
                    }
                }

            if !cleanText.isEmpty {
                Text(cleanText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(expandText ? nil : 4)
            }
        } else if !cleanText.isEmpty {
            Text(cleanText)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .lineLimit(expandText ? nil : 5)
                .onTapGesture {
                    if !workflow.isRead {
                        onToggleRead()
                    }
                }
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
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.08), in: Capsule())
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
                        .background(Color.black.opacity(0.05), in: Capsule())
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            smallActionButton(
                icon: workflow.isPinned ? "pin.fill" : "pin",
                active: workflow.isPinned,
                tint: .orange,
                action: onTogglePinned
            )

            smallActionButton(
                icon: workflow.isStarred ? "star.fill" : "star",
                active: workflow.isStarred,
                tint: .yellow,
                action: onToggleStarred
            )

            smallActionButton(
                icon: workflow.isReadLater ? "clock.fill" : "clock",
                active: workflow.isReadLater,
                tint: .blue,
                action: onToggleReadLater
            )

            smallActionButton(
                icon: workflow.isRead ? "eye.fill" : "eye.slash",
                active: workflow.isRead,
                tint: .secondary,
                action: onToggleRead
            )

            Spacer(minLength: 6)

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
                        .font(.caption.weight(.semibold))
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

    private func smallActionButton(icon: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? tint : .secondary)
                .frame(width: 30, height: 26)
                .background(
                    (active ? tint.opacity(0.16) : Color.black.opacity(0.05)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
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
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
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

    private var sideAccentColor: Color? {
        switch item.level.uppercased() {
        case "A":
            return Color.red.opacity(0.88)
        case "B":
            return Color.orange.opacity(0.82)
        default:
            return nil
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
}
