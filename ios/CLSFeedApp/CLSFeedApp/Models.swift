import Foundation

enum NewsSource: String, CaseIterable, Identifiable, Codable {
    case cls
    case eastmoney
    case sina
    case wscn
    case ths

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cls:
            return "财联社"
        case .eastmoney:
            return "东方财富"
        case .sina:
            return "新浪财经"
        case .wscn:
            return "华尔街见闻"
        case .ths:
            return "同花顺"
        }
    }
}

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case deepseek
    case openai
    case gemini
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek:
            return "DeepSeek"
        case .openai:
            return "OpenAI"
        case .gemini:
            return "Gemini"
        case .custom:
            return "Custom"
        }
    }

    var defaultApiBase: String {
        switch self {
        case .deepseek:
            return "https://api.deepseek.com/v1"
        case .openai:
            return "https://api.openai.com/v1"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom:
            return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek:
            return "deepseek-chat"
        case .openai:
            return "gpt-4.1-mini"
        case .gemini:
            return "gemini-2.0-flash"
        case .custom:
            return ""
        }
    }
}

struct TelegraphItem: Codable, Identifiable, Hashable {
    let uid: String
    let source: String
    let sourceName: String
    let ctime: Int
    let time: String
    let title: String
    let text: String
    let author: String
    let level: String
    let url: String

    var id: String { uid }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FeedFilterOption: String, CaseIterable, Identifiable, Codable {
    case all
    case unread
    case starred
    case later
    case important

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "全部"
        case .unread:
            return "未读"
        case .starred:
            return "收藏"
        case .later:
            return "稍后看"
        case .important:
            return "重要"
        }
    }
}

struct TelegraphWorkflowState: Hashable {
    let isPinned: Bool
    let isStarred: Bool
    let isReadLater: Bool
    let isRead: Bool
}

struct KeywordSubscription: Codable, Identifiable, Hashable {
    let id: String
    var keyword: String
    var isEnabled: Bool
    var createdAt: Int

    init(id: String = UUID().uuidString, keyword: String, isEnabled: Bool = true, createdAt: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id
        self.keyword = keyword
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

struct SourceHealth: Decodable, Hashable {
    let source: String
    let sourceName: String
    let ok: Bool
    let count: Int
    let error: String?
}

struct TelegraphResponse: Decodable {
    let ok: Bool
    let fetchedAt: String?
    let items: [TelegraphItem]
    let sources: [SourceHealth]?
    let selectedSources: [String]?
}

struct TelegraphCluster: Identifiable, Hashable {
    let id: String
    let items: [TelegraphItem]

    var primary: TelegraphItem { items[0] }
    var variants: [TelegraphItem] { Array(items.dropFirst()) }
    var mergedCount: Int { items.count }
    var isMerged: Bool { items.count > 1 }

    var sourceNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            if seen.insert(item.sourceName).inserted {
                out.append(item.sourceName)
            }
        }
        return out
    }
}

struct StockQuote: Hashable, Identifiable {
    let code: String
    let name: String
    let price: Double
    let changePercent: Double
    let updatedAt: Date

    var id: String { code }

    var changeText: String {
        let sign = changePercent > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", changePercent))%"
    }
}

struct AIAnalysis: Codable, Hashable {
    let sentiment: String
    let score: Int
    let confidence: Double
    let horizon: String
    let summary: String
    let actionSummary: String
    let tradeIdeas: [String]
    let riskAlerts: [String]
    let positiveFactors: [String]
    let negativeFactors: [String]
    let bullishTargets: [String]
    let bearishTargets: [String]
    let impactTargets: [String]
    let model: String?
    let provider: String?
    let analyzedAt: String?

    enum CodingKeys: String, CodingKey {
        case sentiment
        case score
        case confidence
        case horizon
        case summary
        case actionSummary = "action_summary"
        case tradeIdeas = "trade_ideas"
        case riskAlerts = "risk_alerts"
        case positiveFactors = "positive_factors"
        case negativeFactors = "negative_factors"
        case bullishTargets = "bullish_targets"
        case bearishTargets = "bearish_targets"
        case impactTargets = "impact_targets"
        case model
        case provider
        case analyzedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sentiment = try c.decodeIfPresent(String.self, forKey: .sentiment) ?? "neutral"
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        horizon = try c.decodeIfPresent(String.self, forKey: .horizon) ?? "short_term"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        actionSummary = try c.decodeIfPresent(String.self, forKey: .actionSummary) ?? ""
        tradeIdeas = try c.decodeIfPresent([String].self, forKey: .tradeIdeas) ?? []
        riskAlerts = try c.decodeIfPresent([String].self, forKey: .riskAlerts) ?? []
        positiveFactors = try c.decodeIfPresent([String].self, forKey: .positiveFactors) ?? []
        negativeFactors = try c.decodeIfPresent([String].self, forKey: .negativeFactors) ?? []
        bullishTargets = try c.decodeIfPresent([String].self, forKey: .bullishTargets) ?? []
        bearishTargets = try c.decodeIfPresent([String].self, forKey: .bearishTargets) ?? []
        impactTargets = try c.decodeIfPresent([String].self, forKey: .impactTargets) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        analyzedAt = try c.decodeIfPresent(String.self, forKey: .analyzedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sentiment, forKey: .sentiment)
        try c.encode(score, forKey: .score)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(horizon, forKey: .horizon)
        try c.encode(summary, forKey: .summary)
        try c.encode(actionSummary, forKey: .actionSummary)
        try c.encode(tradeIdeas, forKey: .tradeIdeas)
        try c.encode(riskAlerts, forKey: .riskAlerts)
        try c.encode(positiveFactors, forKey: .positiveFactors)
        try c.encode(negativeFactors, forKey: .negativeFactors)
        try c.encode(bullishTargets, forKey: .bullishTargets)
        try c.encode(bearishTargets, forKey: .bearishTargets)
        try c.encode(impactTargets, forKey: .impactTargets)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(analyzedAt, forKey: .analyzedAt)
    }

    var sentimentText: String {
        switch sentiment.lowercased() {
        case "bullish", "positive":
            return "偏利好"
        case "bearish", "negative":
            return "偏利空"
        default:
            return "中性"
        }
    }
}
