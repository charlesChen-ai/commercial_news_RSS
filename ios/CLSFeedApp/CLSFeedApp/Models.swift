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

enum PushDeliveryMode: String, CaseIterable, Identifiable, Codable {
    case all
    case keywordsOnly
    case highPriorityOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "全部快讯"
        case .keywordsOnly:
            return "只推关键词"
        case .highPriorityOnly:
            return "只推高优先级"
        }
    }
}

struct PushStrategySnapshot: Codable, Hashable {
    var deliveryMode: PushDeliveryMode
    var tradingHoursOnly: Bool
    var doNotDisturbEnabled: Bool
    var doNotDisturbStart: String
    var doNotDisturbEnd: String
    var rateLimitPerHour: Int
    var sourceCodes: [String]

    static let `default` = PushStrategySnapshot(
        deliveryMode: .all,
        tradingHoursOnly: false,
        doNotDisturbEnabled: false,
        doNotDisturbStart: "22:30",
        doNotDisturbEnd: "07:30",
        rateLimitPerHour: 8,
        sourceCodes: NewsSource.allCases.map(\.rawValue)
    )
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

struct TelegraphCursorPoint: Hashable {
    let ctime: Int
    let uid: String
}

enum TelegraphCursor {
    static func encode(ctime: Int, uid: String) -> String {
        let raw = "\(max(0, ctime))|\(uid)"
        return Data(raw.utf8).base64EncodedString()
    }

    static func decode(_ token: String?) -> TelegraphCursorPoint? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = Data(base64Encoded: trimmed),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let ctime = Int(parts[0]), !parts[1].isEmpty else {
            return nil
        }
        return TelegraphCursorPoint(ctime: ctime, uid: parts[1])
    }

    static func isAfter(_ item: TelegraphItem, cursor: TelegraphCursorPoint) -> Bool {
        if item.ctime != cursor.ctime {
            return item.ctime > cursor.ctime
        }
        return item.uid > cursor.uid
    }
}

enum FeedFilterOption: String, CaseIterable, Identifiable, Codable {
    case all
    case starred
    case later

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "全部"
        case .starred:
            return "收藏"
        case .later:
            return "稍后看"
        }
    }
}

struct FeedQualitySnapshot: Codable, Hashable {
    var collapseThreshold: Int
    var sourcePriorityByCode: [String: Int]
    var uncollapseUIDs: Set<String>

    static let `default` = FeedQualitySnapshot(
        collapseThreshold: 72,
        sourcePriorityByCode: [:],
        uncollapseUIDs: []
    )

    func priority(for sourceCode: String) -> Int {
        let raw = sourcePriorityByCode[sourceCode] ?? 0
        return max(-3, min(3, raw))
    }
}

struct FeedNoiseReductionStats: Hashable {
    var rawCount: Int
    var clusteredCount: Int
    var reducedCount: Int

    static let empty = FeedNoiseReductionStats(rawCount: 0, clusteredCount: 0, reducedCount: 0)

    var reductionRate: Double {
        guard rawCount > 0 else { return 0 }
        return Double(max(0, reducedCount)) / Double(rawCount)
    }
}

enum FeedQualityPreset: String, CaseIterable, Identifiable {
    case highDedupe
    case balanced
    case keepOriginal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highDedupe:
            return "高去重"
        case .balanced:
            return "均衡"
        case .keepOriginal:
            return "保留原文"
        }
    }

    var threshold: Int {
        switch self {
        case .highDedupe:
            return 62
        case .balanced:
            return 72
        case .keepOriginal:
            return 86
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

struct AccountProfile: Codable, Hashable {
    let accountId: String
    let provider: String
    let phoneMasked: String?
    let appleMasked: String?
    let createdAt: String
}

struct AccountSessionInfo: Codable, Hashable {
    let token: String
    let account: AccountProfile
    let expiresAt: String
}

struct AccountCloudState: Codable, Hashable {
    var starredUIDs: [String]
    var readUIDs: [String]
    var keywordSubscriptions: [KeywordSubscription]
    var selectedSources: [String]
    var pushStrategy: PushStrategySnapshot
    var updatedAt: String

    static let empty = AccountCloudState(
        starredUIDs: [],
        readUIDs: [],
        keywordSubscriptions: [],
        selectedSources: NewsSource.allCases.map(\.rawValue),
        pushStrategy: .default,
        updatedAt: ""
    )
}

struct PhoneCodeRequestResponse: Decodable {
    let ok: Bool
    let expiresInSec: Int?
    let debugCode: String?
    let error: String?
}

struct AuthSessionResponse: Decodable {
    let ok: Bool
    let session: AccountSessionInfo?
    let error: String?
}

struct AccountCloudStateResponse: Decodable {
    let ok: Bool
    let cloudState: AccountCloudState?
    let serverUpdatedAt: String?
    let error: String?
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
    let cursor: String?
    let nextCursor: String?
    let incremental: Bool?
}

struct TelegraphCluster: Identifiable, Hashable {
    let id: String
    let items: [TelegraphItem]
    let mergeReason: String?
    let mergeScore: Int

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

    init(id: String, items: [TelegraphItem], mergeReason: String? = nil, mergeScore: Int = 0) {
        self.id = id
        self.items = items
        self.mergeReason = mergeReason
        self.mergeScore = mergeScore
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
