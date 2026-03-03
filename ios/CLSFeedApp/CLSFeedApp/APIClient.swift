import Foundation

enum APIClientError: LocalizedError {
    case invalidBaseURL
    case badServerResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "服务地址无效"
        case .badServerResponse(let reason):
            return reason
        }
    }
}

struct AnalyzeRequest: Encodable {
    struct AIConfig: Encodable {
        let provider: String
        let apiKey: String
        let apiBase: String
        let model: String
    }

    let uid: String
    let source: String
    let time: String
    let title: String
    let text: String
    let ai: AIConfig
}

struct AnalyzeResponse: Decodable {
    let ok: Bool
    let analysis: AIAnalysis?
    let error: String?
}

private struct APIErrorResponse: Decodable {
    let error: String?
}

final class APIClient {
    static let shared = APIClient()

    private let decoder = JSONDecoder()
    private let session = URLSession(configuration: .ephemeral)
    private let localAggregator = LocalTelegraphAggregator()

    private init() {}

    func fetchTelegraph(baseURL: String, limit: Int, sources: [NewsSource]) async throws -> TelegraphResponse {
        if isLocalMode(baseURL: baseURL) {
            return try await localAggregator.fetch(limit: limit, sources: sources)
        }

        let requestURL = try buildURL(baseURL: baseURL, path: "/api/telegraph") { components in
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "sources", value: sources.map(\.rawValue).joined(separator: ","))
            ]
        }

        let (data, response) = try await session.data(from: requestURL)
        try validateHTTP(response: response, data: data)
        let result = try decoder.decode(TelegraphResponse.self, from: data)
        if !result.ok {
            throw APIClientError.badServerResponse("服务端返回失败")
        }
        return result
    }

    func analyze(baseURL: String, item: TelegraphItem, ai: AIConfigSnapshot) async throws -> AIAnalysis {
        if isLocalMode(baseURL: baseURL) {
            return try await analyzeDirect(item: item, ai: ai)
        }

        let requestURL = try buildURL(baseURL: baseURL, path: "/api/analyze")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = AnalyzeRequest(
            uid: item.uid,
            source: item.source,
            time: item.time,
            title: item.title,
            text: item.text,
            ai: .init(
                provider: ai.provider.rawValue,
                apiKey: ai.apiKey,
                apiBase: ai.apiBase,
                model: ai.model
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        let result = try decoder.decode(AnalyzeResponse.self, from: data)

        guard result.ok else {
            throw APIClientError.badServerResponse(result.error ?? "AI 分析失败")
        }
        guard let analysis = result.analysis else {
            throw APIClientError.badServerResponse("AI 分析结果为空")
        }

        return analysis
    }

    private func analyzeDirect(item: TelegraphItem, ai: AIConfigSnapshot) async throws -> AIAnalysis {
        let apiKey = ai.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiBase = ai.apiBase.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let model = ai.model.trimmingCharacters(in: .whitespacesAndNewlines)

        if apiKey.isEmpty {
            throw APIClientError.badServerResponse("请先在控制台输入 AI API Key")
        }
        if apiBase.isEmpty {
            throw APIClientError.badServerResponse("请先在控制台填写 AI API Base")
        }
        if model.isEmpty {
            throw APIClientError.badServerResponse("请先在控制台填写 AI Model")
        }

        guard let endpoint = URL(string: "\(apiBase)/chat/completions") else {
            throw APIClientError.badServerResponse("AI API Base 无效")
        }

        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && text.isEmpty {
            throw APIClientError.badServerResponse("AI 输入为空")
        }

        let systemPrompt =
            "你是资深A股/港股/宏观快讯分析师。任务是“分析这条新闻对市场可能产生的影响”，并给出简要说明。" +
            "请先识别新闻类型（宏观/行业/公司/地缘/商品/政策），再判断影响方向与影响路径（例如：供需变化、风险偏好、估值、盈利预期、资金面）。" +
            "评分与结论时，优先考虑未来1~2个交易日的情绪冲击与资金流影响：短期交易性影响权重约70%，中期基本面影响权重约30%。" +
            "若短期与中期信号冲突，优先按短期给出sentiment和score，并在summary里点明冲突来源。" +
            "必须只输出JSON，不要输出任何额外文本。" +
            "JSON字段: sentiment(bullish|bearish|neutral), score(-100~100), confidence(0~1), horizon(short_term|mid_term), summary, action_summary, trade_ideas(array), risk_alerts(array), positive_factors(array), negative_factors(array), bullish_targets(array), bearish_targets(array), impact_targets(array)。" +
            "summary要求: 1~2句、简洁、可读，说明“为什么偏利好/偏利空/中性”；长度尽量控制在80字以内。" +
            "action_summary要求: 1句中文，明确“偏交易结论/观察结论”，比如更偏短线跟踪、回避或中性等待，不要给确定收益承诺。" +
            "trade_ideas最多3条，每条不超过22字，优先写“板块/个股 + 触发逻辑”。" +
            "risk_alerts最多3条，每条不超过22字，写关键证伪点或反向风险。" +
            "positive_factors/negative_factors各最多3条，每条一句短语。" +
            "bullish_targets/bearish_targets要求给出具体方向：优先写板块或个股名称，能定位个股时可附股票代码；每个数组0~4条。" +
            "impact_targets可作为总览补充（0~6条），不要与bullish_targets/bearish_targets完全重复。" +
            "当信息不足或新闻真假不明时，用neutral并降低confidence，score靠近0。"

        let userPayload: [String: Any] = [
            "task": "请分析这条快讯的潜在市场影响，并给出简要说明。",
            "source": item.source,
            "time": item.time,
            "title": title,
            "text": text
        ]
        let userJSON = String(decoding: try JSONSerialization.data(withJSONObject: userPayload, options: [.prettyPrinted]), as: UTF8.self)

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.15,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userJSON]
            ]
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.badServerResponse("AI 服务响应异常")
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(decoding: data, as: UTF8.self)
            throw APIClientError.badServerResponse("AI HTTP \(http.statusCode): \(raw.prefix(200))")
        }

        guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = outer["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw APIClientError.badServerResponse("AI 返回格式异常")
        }

        guard let parsed = parseFirstJSONObject(from: content) else {
            throw APIClientError.badServerResponse("AI 未返回可解析的 JSON")
        }

        let normalized = normalizeAIResult(parsed: parsed, model: model, provider: ai.provider.rawValue)
        let normalizedData = try JSONSerialization.data(withJSONObject: normalized)
        return try decoder.decode(AIAnalysis.self, from: normalizedData)
    }

    private func isLocalMode(baseURL: String) -> Bool {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty || raw == "local" || raw.hasPrefix("app://local") {
            return true
        }
        if raw.contains("://localhost") || raw.contains("://127.0.0.1") {
            return true
        }
        return false
    }

    private func buildURL(baseURL: String, path: String, mutate: ((inout URLComponents) -> Void)? = nil) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard var components = URLComponents(string: trimmed) else {
            throw APIClientError.invalidBaseURL
        }

        components.path = path
        mutate?(&components)

        guard let url = components.url else {
            throw APIClientError.invalidBaseURL
        }
        return url
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            if let payload = try? decoder.decode(APIErrorResponse.self, from: data),
               let error = payload.error,
               !error.isEmpty {
                throw APIClientError.badServerResponse(error)
            }
            throw APIClientError.badServerResponse("HTTP \(http.statusCode)")
        }
    }

    private func parseFirstJSONObject(from text: String) -> [String: Any]? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }

        if raw.hasPrefix("{"), raw.hasSuffix("}") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                return obj
            }
        }

        if let fencedRange = raw.range(of: #"```(?:json)?\s*([\s\S]*?)\s*```"#, options: .regularExpression) {
            let fenced = String(raw[fencedRange])
            let stripped = fenced
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            if let obj = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] {
                return obj
            }
        }

        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false

        var idx = start
        while idx < raw.endIndex {
            let ch = raw[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let frag = String(raw[start...idx])
                        return (try? JSONSerialization.jsonObject(with: Data(frag.utf8))) as? [String: Any]
                    }
                }
            }
            idx = raw.index(after: idx)
        }
        return nil
    }

    private func normalizeAIResult(parsed: [String: Any], model: String, provider: String) -> [String: Any] {
        let rawSentiment = String(describing: parsed["sentiment"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sentiment: String
        if ["bullish", "positive", "利好", "看多"].contains(rawSentiment) {
            sentiment = "bullish"
        } else if ["bearish", "negative", "利空", "看空"].contains(rawSentiment) {
            sentiment = "bearish"
        } else {
            sentiment = "neutral"
        }

        let score = Int(clamp(doubleValue(parsed["score"]), min: -100, max: 100).rounded())
        let confidence = (clamp(doubleValue(parsed["confidence"]), min: 0, max: 1) * 100).rounded() / 100
        let horizon = truncate(String(describing: parsed["horizon"] ?? "short_term"), max: 24).nonEmpty ?? "short_term"
        let summary = truncate(String(describing: parsed["summary"] ?? ""), max: 240)
        let actionRaw = truncate(String(describing: parsed["action_summary"] ?? ""), max: 120)
        let actionSummary: String
        if let nonEmpty = actionRaw.nonEmpty {
            actionSummary = nonEmpty
        } else {
            switch sentiment {
            case "bullish":
                actionSummary = "短线偏交易性利好，可优先跟踪最直接受益方向。"
            case "bearish":
                actionSummary = "短线偏风险释放，宜先控制仓位并观察二次确认。"
            default:
                actionSummary = "短线方向不清晰，建议等待增量信息再决策。"
            }
        }
        let impactTargets = normalizeStringArray(parsed["impact_targets"], limit: 6)
        let bullishTargets = normalizeStringArray(parsed["bullish_targets"], limit: 4)
        let bearishTargets = normalizeStringArray(parsed["bearish_targets"], limit: 4)

        return [
            "sentiment": sentiment,
            "score": score,
            "confidence": confidence,
            "horizon": horizon,
            "summary": summary,
            "action_summary": actionSummary,
            "trade_ideas": normalizeStringArray(parsed["trade_ideas"], limit: 3),
            "risk_alerts": normalizeStringArray(parsed["risk_alerts"], limit: 3),
            "positive_factors": normalizeStringArray(parsed["positive_factors"], limit: 3),
            "negative_factors": normalizeStringArray(parsed["negative_factors"], limit: 3),
            "impact_targets": impactTargets,
            "bullish_targets": bullishTargets,
            "bearish_targets": bearishTargets,
            "model": model,
            "provider": provider,
            "analyzedAt": ISO8601DateFormatter().string(from: Date())
        ]
    }

    private func normalizeStringArray(_ raw: Any?, limit: Int) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [String] = []
        for item in arr {
            let value = truncate(String(describing: item).trimmingCharacters(in: .whitespacesAndNewlines), max: 120)
            if value.isEmpty { continue }
            out.append(value)
            if out.count >= limit { break }
        }
        return out
    }

    private func doubleValue(_ raw: Any?) -> Double {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let d = Double(s) { return d }
        return 0
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private func truncate(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max))
    }
}

private extension String {
    var nonEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
