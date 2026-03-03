import Foundation

private enum LocalAggregatorError: LocalizedError {
    case noSourceAvailable(String)
    case sourceFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSourceAvailable(let reason):
            return "全部信息源抓取失败: \(reason)"
        case .sourceFailed(let reason):
            return reason
        }
    }
}

private struct SourceResult {
    let source: NewsSource
    let sourceName: String
    let items: [TelegraphItem]
    let error: String?

    var ok: Bool { error == nil }
}

final class LocalTelegraphAggregator {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func fetch(limit: Int, sources: [NewsSource]) async throws -> TelegraphResponse {
        let chosen = sources.isEmpty ? NewsSource.allCases : sources
        let perSourceLimit = max(20, min(180, Int(ceil(Double(limit) * 1.4))))

        let results = await withTaskGroup(of: SourceResult.self) { group in
            for source in chosen {
                group.addTask { [weak self] in
                    guard let self else {
                        return SourceResult(source: source, sourceName: source.displayName, items: [], error: "aggregator_deallocated")
                    }

                    do {
                        let items = try await self.fetchOne(source: source, limit: perSourceLimit)
                        return SourceResult(source: source, sourceName: source.displayName, items: items, error: nil)
                    } catch {
                        return SourceResult(source: source, sourceName: source.displayName, items: [], error: error.localizedDescription)
                    }
                }
            }

            var merged: [SourceResult] = []
            for await result in group {
                merged.append(result)
            }
            return merged
        }

        let successful = results.filter(\.ok)
        if successful.isEmpty {
            let reason = results.map { "\($0.source.rawValue):\($0.error ?? "failed")" }.joined(separator: ",")
            throw LocalAggregatorError.noSourceAvailable(reason)
        }

        var combined = results.flatMap(\.items)
        combined.sort {
            if $0.ctime != $1.ctime { return $0.ctime > $1.ctime }
            return $0.uid > $1.uid
        }

        // Keep multi-source variants for client-side event clustering.
        let uidUnique = dedupeByUID(combined)

        let health = chosen.map { source in
            let matched = results.first { $0.source == source }
            if let matched {
                return SourceHealth(
                    source: source.rawValue,
                    sourceName: source.displayName,
                    ok: matched.ok,
                    count: matched.items.count,
                    error: matched.error
                )
            }
            return SourceHealth(source: source.rawValue, sourceName: source.displayName, ok: false, count: 0, error: "source_not_found")
        }

        return TelegraphResponse(
            ok: true,
            fetchedAt: ISO8601DateFormatter().string(from: Date()),
            items: Array(uidUnique.prefix(limit)),
            sources: health,
            selectedSources: chosen.map(\.rawValue)
        )
    }

    private func fetchOne(source: NewsSource, limit: Int) async throws -> [TelegraphItem] {
        switch source {
        case .cls:
            return try await fetchCLS(limit: limit)
        case .eastmoney:
            return try await fetchEastmoney(limit: limit)
        case .sina:
            return try await fetchSina(limit: limit)
        case .wscn:
            return try await fetchWSCN(limit: limit)
        case .ths:
            return try await fetchTHS(limit: limit)
        }
    }

    private func fetchText(url: String, headers: [String: String] = [:]) async throws -> String {
        guard let endpoint = URL(string: url) else {
            throw LocalAggregatorError.sourceFailed("invalid_url")
        }

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 18
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.setValue("keep-alive", forHTTPHeaderField: "Connection")

        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LocalAggregatorError.sourceFailed("http_\(status)")
        }

        let text = String(decoding: data, as: UTF8.self)
        if text.contains("访问被拦截") || text.localizedCaseInsensitiveContains("The access is blocked") {
            throw LocalAggregatorError.sourceFailed("waf_blocked")
        }
        return text
    }

    private func fetchCLS(limit: Int) async throws -> [TelegraphItem] {
        let attempts: [(String, String, [String: String])] = [
            ("desktop", "https://www.cls.cn/telegraph", ["Referer": "https://www.cls.cn/"]),
            ("desktop_slash", "https://www.cls.cn/telegraph/", ["Referer": "https://www.cls.cn/"]),
            ("mobile_fallback", "https://m.cls.cn/telegraph", ["Referer": "https://m.cls.cn/"])
        ]

        var lastError = "cls_fetch_failed"

        for attempt in attempts {
            do {
                let html = try await fetchText(url: attempt.1, headers: attempt.2)
                guard let jsonText = extractNextDataJSON(html) else {
                    throw LocalAggregatorError.sourceFailed("next_data_not_found")
                }

                let data = try parseJSONAny(jsonText)
                let rawList = extractCLSRawList(data)
                if rawList.isEmpty {
                    throw LocalAggregatorError.sourceFailed("cls_raw_list_empty")
                }

                var items: [TelegraphItem] = []
                var seen = Set<String>()

                for row in rawList {
                    let id = intString(row["id"])
                    if id.isEmpty || seen.contains(id) { continue }
                    seen.insert(id)

                    let content = stripTags(anyString(row["content"]).nonEmpty ?? anyString(row["brief"]).nonEmpty ?? anyString(row["title"]))
                    if content.isEmpty { continue }

                    let ctime = toEpochSeconds(row["ctime"]) > 0
                        ? toEpochSeconds(row["ctime"])
                        : (toEpochSeconds(row["modified_time"]) > 0 ? toEpochSeconds(row["modified_time"]) : toEpochSeconds(row["sort_score"]))

                    if let item = normalizeItem(
                        source: .cls,
                        sourceName: "财联社",
                        id: id,
                        ctime: ctime,
                        time: anyString(row["time"]),
                        title: anyString(row["title"]),
                        text: content,
                        author: anyString(row["author"]),
                        level: anyString(row["level"]).isEmpty ? "B" : anyString(row["level"]),
                        url: anyString(row["shareurl"])
                    ) {
                        items.append(item)
                    }
                }

                items.sort { $0.ctime == $1.ctime ? $0.uid > $1.uid : $0.ctime > $1.ctime }
                if !items.isEmpty {
                    return Array(items.prefix(limit))
                }
                throw LocalAggregatorError.sourceFailed("cls_items_empty")
            } catch {
                lastError = "\(attempt.0):\(error.localizedDescription)"
            }
        }

        throw LocalAggregatorError.sourceFailed(lastError)
    }

    private func fetchEastmoney(limit: Int) async throws -> [TelegraphItem] {
        let safeLimit = max(20, min(100, limit))
        let trace = "\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
        let url = "https://np-weblist.eastmoney.com/comm/web/getFastNewsList?client=web&biz=web_724&fastColumn=102&sortEnd=&pageSize=\(safeLimit)&req_trace=\(trace)&callback=cb"

        let raw = try await fetchText(url: url, headers: [
            "Referer": "https://kuaixun.eastmoney.com/",
            "Accept": "*/*"
        ])

        let jsonBody = try parseJSONP(raw)
        let root = try parseJSONObject(jsonBody)
        let list = path(root, ["data", "fastNewsList"]) as? [[String: Any]] ?? []

        var items: [TelegraphItem] = []
        for row in list {
            let id = anyString(row["code"]).nonEmpty ?? anyString(row["realSort"])
            let text = stripTags(anyString(row["summary"]).nonEmpty ?? anyString(row["title"]))
            if text.isEmpty || id.isEmpty { continue }

            let ctime = max(toEpochSeconds(row["realSort"]), toEpochSeconds(row["showTime"]))
            let code = anyString(row["code"])
            let url = code.isEmpty ? "https://kuaixun.eastmoney.com/" : "https://finance.eastmoney.com/a/\(code).html"

            let level = (anyInt(row["titleColor"]) == 1) ? "B" : "C"

            if let item = normalizeItem(
                source: .eastmoney,
                sourceName: "东方财富",
                id: id,
                ctime: ctime,
                time: String(anyString(row["showTime"]).suffix(8)),
                title: anyString(row["title"]),
                text: text,
                author: "东方财富",
                level: level,
                url: url
            ) {
                items.append(item)
            }
        }

        items.sort { $0.ctime == $1.ctime ? $0.uid > $1.uid : $0.ctime > $1.ctime }
        return Array(items.prefix(limit))
    }

    private func fetchSina(limit: Int) async throws -> [TelegraphItem] {
        let safeLimit = max(20, min(80, limit))
        let url = "https://zhibo.sina.com.cn/api/zhibo/feed?zhibo_id=152&tag_id=0&page=1&page_size=\(safeLimit)&dire=f&dpc=1&callback=cb"

        let raw = try await fetchText(url: url, headers: [
            "Referer": "https://finance.sina.com.cn/7x24/",
            "Accept": "*/*"
        ])

        let jsonBody = try parseJSONP(raw)
        let root = try parseJSONObject(jsonBody)
        let list = path(root, ["result", "data", "feed", "list"]) as? [[String: Any]] ?? []

        var items: [TelegraphItem] = []

        for row in list {
            let content = stripTags(anyString(row["rich_text"]).nonEmpty ?? anyString(row["content"]))
            if content.isEmpty { continue }

            let title = extractBracketTitle(content)

            if let item = normalizeItem(
                source: .sina,
                sourceName: "新浪财经",
                id: intString(row["id"]),
                ctime: toEpochSeconds(row["create_time"]),
                time: String(anyString(row["create_time"]).suffix(8)),
                title: title,
                text: content,
                author: anyString(row["creator"]).nonEmpty ?? anyString(row["anchor_nick"]).nonEmpty ?? "新浪财经",
                level: (anyInt(row["top_value"]) > 0) ? "B" : "C",
                url: intString(row["id"]).isEmpty ? "https://finance.sina.com.cn/7x24/" : "https://finance.sina.com.cn/7x24/\(intString(row["id"])).shtml"
            ) {
                items.append(item)
            }
        }

        items.sort { $0.ctime == $1.ctime ? $0.uid > $1.uid : $0.ctime > $1.ctime }
        return Array(items.prefix(limit))
    }

    private func fetchWSCN(limit: Int) async throws -> [TelegraphItem] {
        let html = try await fetchText(url: "https://wallstreetcn.com/live", headers: [
            "Referer": "https://wallstreetcn.com/live",
            "User-Agent": "Mozilla/5.0"
        ])

        var rows: [[String: Any]] = []

        if let livesText = extractJSONArrayByKey(html: html, key: "lives"),
           let parsed = try? parseJSONAny(livesText) as? [[String: Any]] {
            rows = parsed
        }

        if rows.isEmpty,
           let ssrText = extractAssignedJSONObject(html: html, varName: "__SSR__"),
           let ssrRoot = try? parseJSONObject(ssrText),
           let ssrLives = path(ssrRoot, ["state", "default", "children", "default", "data", "lives"]) as? [[String: Any]] {
            rows = ssrLives
        }

        if rows.isEmpty {
            throw LocalAggregatorError.sourceFailed("wscn_lives_not_found")
        }

        var items: [TelegraphItem] = []

        for row in rows {
            let content = stripTags(anyString(row["content_text"]).nonEmpty ?? anyString(row["content"]).nonEmpty ?? anyString(row["title"]))
            if content.isEmpty { continue }

            let score = anyInt(row["score"])
            let level: String
            if score >= 3 {
                level = "A"
            } else if score >= 2 {
                level = "B"
            } else {
                level = "C"
            }

            let author: String = {
                if let dict = row["author"] as? [String: Any] {
                    return anyString(dict["display_name"]).nonEmpty ?? "华尔街见闻"
                }
                return "华尔街见闻"
            }()

            if let item = normalizeItem(
                source: .wscn,
                sourceName: "华尔街见闻",
                id: intString(row["id"]),
                ctime: toEpochSeconds(row["display_time"]),
                time: "",
                title: anyString(row["title"]),
                text: content,
                author: author,
                level: level,
                url: anyString(row["uri"])
            ) {
                items.append(item)
            }
        }

        items.sort { $0.ctime == $1.ctime ? $0.uid > $1.uid : $0.ctime > $1.ctime }
        return Array(items.prefix(limit))
    }

    private func fetchTHS(limit: Int) async throws -> [TelegraphItem] {
        let html = try await fetchText(url: "https://www.10jqka.com.cn/", headers: ["Referer": "https://www.10jqka.com.cn/"])
        let rows = extractTHSRows(from: html)
        if rows.isEmpty {
            throw LocalAggregatorError.sourceFailed("ths_rows_not_found")
        }

        var items: [TelegraphItem] = []

        for row in rows {
            let content = stripTags(anyString(row["summary"]).nonEmpty ?? anyString(row["title"]))
            if content.isEmpty { continue }

            if let item = normalizeItem(
                source: .ths,
                sourceName: "同花顺",
                id: intString(row["id"]).nonEmpty ?? intString(row["seq"]),
                ctime: max(toEpochSeconds(row["createTime"]), toEpochSeconds(row["ctime"])),
                time: "",
                title: anyString(row["title"]),
                text: content,
                author: "同花顺",
                level: anyInt(row["type"]) == 1 ? "B" : "C",
                url: anyString(row["url"]).nonEmpty ?? anyString(row["shareUrl"])
            ) {
                items.append(item)
            }
        }

        items.sort { $0.ctime == $1.ctime ? $0.uid > $1.uid : $0.ctime > $1.ctime }
        return Array(items.prefix(limit))
    }

    private func normalizeItem(
        source: NewsSource,
        sourceName: String,
        id: String,
        ctime: Int,
        time: String,
        title: String,
        text: String,
        author: String,
        level: String,
        url: String
    ) -> TelegraphItem? {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanID.isEmpty, !cleanText.isEmpty else { return nil }

        let epoch = ctime > 0 ? ctime : toEpochSeconds(time)
        let displayTime = time.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? formatTime(epoch)

        return TelegraphItem(
            uid: "\(source.rawValue):\(cleanID)",
            source: source.rawValue,
            sourceName: sourceName,
            ctime: epoch,
            time: displayTime,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            text: cleanText,
            author: author.trimmingCharacters(in: .whitespacesAndNewlines),
            level: level.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Dedupe

private func dedupeByUID(_ items: [TelegraphItem]) -> [TelegraphItem] {
    var seen = Set<String>()
    var out: [TelegraphItem] = []
    for item in items {
        if seen.contains(item.uid) { continue }
        seen.insert(item.uid)
        out.append(item)
    }
    return out
}

private func normalizeNewsForDedupe(_ text: String) -> String {
    var value = text.lowercased()
    value = regexReplace(value, pattern: "https?://\\S+", with: " ")
    value = regexReplace(value, pattern: "^【[^】]{2,30}】\\s*", with: "")
    value = regexReplace(value, pattern: "^(财联社|新浪财经|华尔街见闻|同花顺|东方财富)(\\d{1,2}月\\d{1,2}日)?电[，,:：\\s]*", with: "")
    value = regexReplace(value, pattern: "^[\\p{Han}a-z0-9%]{0,16}电[，,:：\\s]*", with: "")
    value = regexReplace(value, pattern: "[^\\p{Han}a-z0-9%]+", with: " ")
    value = regexReplace(value, pattern: "\\s+", with: " ")
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func buildStrongContentKey(_ item: TelegraphItem) -> String {
    let t1 = normalizeNewsForDedupe(item.title)
    let t2 = normalizeNewsForDedupe(item.text)
    if t1.isEmpty && t2.isEmpty { return "" }
    let key = "\(t1)|\(t2)"
    return key.count > 1200 ? String(key.prefix(1200)) : key
}

private func dedupeByStrongContent(_ items: [TelegraphItem]) -> [TelegraphItem] {
    var seen = Set<String>()
    var out: [TelegraphItem] = []
    for item in items {
        let key = buildStrongContentKey(item)
        if !key.isEmpty, seen.contains(key) { continue }
        if !key.isEmpty { seen.insert(key) }
        out.append(item)
    }
    return out
}

private func normalizeTitleForDedupe(_ title: String) -> String {
    let lowered = title.lowercased()
    let cleaned = regexReplace(lowered, pattern: "[^\\p{Han}a-z0-9%]+", with: "")
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func dedupeByExactTitle(_ items: [TelegraphItem], windowSec: Int = 1800) -> [TelegraphItem] {
    var out: [TelegraphItem] = []
    var recentByTitle: [String: (ctime: Int, uid: String)] = [:]

    for item in items {
        let titleKey = normalizeTitleForDedupe(item.title)
        let ctime = item.ctime

        if titleKey.count < 8 {
            out.append(item)
            continue
        }

        if let prev = recentByTitle[titleKey] {
            let delta = abs(ctime - prev.ctime)
            if delta <= windowSec || ctime == 0 || prev.ctime == 0 {
                continue
            }
        }

        recentByTitle[titleKey] = (ctime, item.uid)
        out.append(item)
    }

    return out
}

private func extractNumberTokens(_ text: String) -> [String] {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let regex = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?%?", options: []) else { return [] }

    var seen = Set<String>()
    var out: [String] = []

    for m in regex.matches(in: text, options: [], range: range) {
        if let r = Range(m.range, in: text) {
            let v = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty || seen.contains(v) { continue }
            seen.insert(v)
            out.append(v)
            if out.count >= 12 { break }
        }
    }

    return out
}

private func numberTokensCompatible(_ a: [String], _ b: [String]) -> Bool {
    if a.isEmpty && b.isEmpty { return true }
    if a.isEmpty || b.isEmpty { return false }

    let setA = Set(a)
    let setB = Set(b)
    let smaller = setA.count <= setB.count ? setA : setB
    let larger = setA.count <= setB.count ? setB : setA

    var hit = 0
    for x in smaller where larger.contains(x) {
        hit += 1
    }

    return Double(hit) / Double(max(1, smaller.count)) >= 0.7
}

private func buildBigrams(_ text: String) -> Set<String> {
    if text.count < 2 { return [] }
    let chars = Array(text)
    var set = Set<String>()
    for i in 0..<(chars.count - 1) {
        set.insert(String(chars[i...i + 1]))
    }
    return set
}

private func diceSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
    if a.isEmpty || b.isEmpty { return 0 }
    let smaller = a.count <= b.count ? a : b
    let larger = a.count <= b.count ? b : a
    var inter = 0
    for token in smaller where larger.contains(token) {
        inter += 1
    }
    return Double(2 * inter) / Double(a.count + b.count)
}

private func dedupeByFuzzyContent(_ items: [TelegraphItem], windowSec: Int = 600, similarityThreshold: Double = 0.88) -> [TelegraphItem] {
    struct Meta {
        let ctime: Int
        let nums: [String]
        let shortNorm: String
        let grams: Set<String>
    }

    var kept: [TelegraphItem] = []
    var metas: [Meta?] = []

    for item in items {
        let normalized = normalizeNewsForDedupe("\(item.title) \(item.text)")
        let ctime = item.ctime

        if normalized.count < 22 || ctime == 0 {
            kept.append(item)
            metas.append(nil)
            continue
        }

        let nums = extractNumberTokens("\(item.title) \(item.text)")
        let shortNorm = normalized.count > 260 ? String(normalized.prefix(260)) : normalized
        let grams = buildBigrams(shortNorm)

        var duplicated = false

        for idx in kept.indices {
            guard let meta = metas[idx] else { continue }

            let dt = abs(ctime - meta.ctime)
            if dt > windowSec { continue }

            let lenMax = max(shortNorm.count, meta.shortNorm.count)
            let lenMin = min(shortNorm.count, meta.shortNorm.count)
            if lenMin == 0 || Double(lenMax) / Double(lenMin) > 1.8 { continue }

            if !numberTokensCompatible(nums, meta.nums) { continue }

            let sim = diceSimilarity(grams, meta.grams)
            if sim >= similarityThreshold {
                duplicated = true
                break
            }
        }

        if !duplicated {
            kept.append(item)
            metas.append(Meta(ctime: ctime, nums: nums, shortNorm: shortNorm, grams: grams))
        }
    }

    return kept
}

// MARK: - Parsing helpers

private func parseJSONAny(_ text: String) throws -> Any {
    let data = Data(text.utf8)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

private func parseJSONObject(_ text: String) throws -> [String: Any] {
    guard let obj = try parseJSONAny(text) as? [String: Any] else {
        throw LocalAggregatorError.sourceFailed("json_not_object")
    }
    return obj
}

private func parseJSONP(_ raw: String) throws -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { throw LocalAggregatorError.sourceFailed("jsonp_empty") }

    if let tryCatch = text.range(of: ");}catch", options: .literal),
       let open = text.firstIndex(of: "(") {
        let body = text[text.index(after: open)..<tryCatch.lowerBound]
        return String(body)
    }

    guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), close > open else {
        throw LocalAggregatorError.sourceFailed("jsonp_bad_wrapper")
    }

    let body = text[text.index(after: open)..<close]
    return String(body)
}

private func path(_ root: [String: Any], _ keys: [String]) -> Any? {
    var current: Any = root
    for key in keys {
        guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
        current = next
    }
    return current
}

private func extractNextDataJSON(_ html: String) -> String? {
    let marker = "<script id=\"__NEXT_DATA__\" type=\"application/json\">"
    if let start = html.range(of: marker) {
        let bodyStart = start.upperBound
        if let end = html.range(of: "</script>", range: bodyStart..<html.endIndex) {
            return String(html[bodyStart..<end.lowerBound])
        }
    }

    if let markerRange = html.range(of: "__NEXT_DATA__ =") {
        let tail = html[markerRange.upperBound...]
        if let openOffset = tail.firstIndex(of: "{") {
            let candidate = String(tail[openOffset...])
            return extractBalancedObject(candidate)
        }
    }

    return nil
}

private func extractBalancedObject(_ text: String) -> String? {
    var depth = 0
    var inString = false
    var escaped = false
    var start: String.Index?

    for idx in text.indices {
        let ch = text[idx]

        if inString {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString = false
            }
            continue
        }

        if ch == "\"" {
            inString = true
            continue
        }

        if ch == "{" {
            if start == nil { start = idx }
            depth += 1
            continue
        }

        if ch == "}" {
            depth -= 1
            if depth == 0, let s = start {
                return String(text[s...idx])
            }
        }
    }

    return nil
}

private func extractJSONArrayByKey(html: String, key: String) -> String? {
    let marker = "\"\(key)\":["
    guard let start = html.range(of: marker)?.lowerBound else { return nil }
    let arrayStart = html.index(start, offsetBy: marker.count - 1)
    return extractBalancedArray(String(html[arrayStart...]))
}

private func extractEscapedJSONArrayByKey(html: String, escapedKey: String) -> String? {
    let marker = "\\\"\(escapedKey)\\\":["
    guard let start = html.range(of: marker)?.lowerBound else { return nil }
    let arrayStart = html.index(start, offsetBy: marker.count - 1)
    return extractBalancedArray(String(html[arrayStart...]))
}

private func extractAssignedJSONArray(html: String, varName: String) -> String? {
    let marker = "\(varName) = "
    guard let markerRange = html.range(of: marker) else { return nil }

    let tail = html[markerRange.upperBound...]
    guard let open = tail.firstIndex(of: "[") else { return nil }
    return extractBalancedArray(String(tail[open...]))
}

private func extractAssignedJSONObject(html: String, varName: String) -> String? {
    let marker = "\(varName) = "
    guard let markerRange = html.range(of: marker) else { return nil }

    let tail = html[markerRange.upperBound...]
    guard let open = tail.firstIndex(of: "{") else { return nil }
    return extractBalancedObject(String(tail[open...]))
}

private func extractBalancedArray(_ text: String) -> String? {
    var depth = 0
    var inString = false
    var escaped = false
    var start: String.Index?

    for idx in text.indices {
        let ch = text[idx]

        if inString {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString = false
            }
            continue
        }

        if ch == "\"" {
            inString = true
            continue
        }

        if ch == "[" {
            if start == nil { start = idx }
            depth += 1
            continue
        }

        if ch == "]" {
            depth -= 1
            if depth == 0, let s = start {
                return String(text[s...idx])
            }
        }
    }

    return nil
}

private func extractCLSRawList(_ rootAny: Any) -> [[String: Any]] {
    guard let root = rootAny as? [String: Any], let props = root["props"] as? [String: Any] else { return [] }

    if let initialRedux = props["initialReduxState"] as? [String: Any],
       let telegraph = initialRedux["telegraph"] as? [String: Any],
       let list = telegraph["telegraphList"] as? [[String: Any]] {
        return list
    }

    if let initialState = props["initialState"] as? [String: Any] {
        if let telegraph = initialState["telegraph"] as? [String: Any],
           let list = telegraph["telegraphList"] as? [[String: Any]] {
            return list
        }

        if let rollData = initialState["roll_data"] as? [[String: Any]] {
            return rollData
        }
    }

    if let pageProps = props["pageProps"] as? [String: Any],
       let rollData = pageProps["roll_data"] as? [[String: Any]] {
        return rollData
    }

    return []
}

private func extractTHSRows(from html: String) -> [[String: Any]] {
    let candidateKeys = ["initialNewsList", "newsList", "flashList", "liveList"]

    for key in candidateKeys {
        if let escaped = extractEscapedJSONArrayByKey(html: html, escapedKey: key),
           let rows = parseJSONArrayText(escaped, escaped: true),
           !rows.isEmpty {
            return rows
        }

        if let plain = extractJSONArrayByKey(html: html, key: key),
           let rows = parseJSONArrayText(plain, escaped: false),
           !rows.isEmpty {
            return rows
        }
    }

    if let assigned = extractAssignedJSONArray(html: html, varName: "initialNewsList"),
       let rows = parseJSONArrayText(assigned, escaped: false),
       !rows.isEmpty {
        return rows
    }

    return []
}

private func parseJSONArrayText(_ text: String, escaped: Bool) -> [[String: Any]]? {
    if !escaped {
        return (try? parseJSONAny(text) as? [[String: Any]]) ?? nil
    }

    let decoded = text
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\/", with: "/")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\r", with: "\r")
        .replacingOccurrences(of: "\\t", with: "\t")
        .replacingOccurrences(of: "\\u0026", with: "&")

    return (try? parseJSONAny(decoded) as? [[String: Any]]) ?? nil
}

private func stripTags(_ html: String) -> String {
    var value = html
    value = regexReplace(value, pattern: "<br\\s*/?>", with: "\n", options: [.caseInsensitive])
    value = regexReplace(value, pattern: "<[^>]+>", with: "")

    let entities: [String: String] = [
        "&nbsp;": " ",
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&#39;": "'"
    ]

    for (k, v) in entities {
        value = value.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
    }

    value = regexReplace(value, pattern: "\\s+\\n", with: "\n")
    value = regexReplace(value, pattern: "\\n\\s+", with: "\n")
    value = regexReplace(value, pattern: "[ \\t]+", with: " ")

    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func regexReplace(
    _ text: String,
    pattern: String,
    with template: String,
    options: NSRegularExpression.Options = []
) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return text
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
}

private func extractBracketTitle(_ content: String) -> String {
    let range = NSRange(content.startIndex..<content.endIndex, in: content)
    guard let regex = try? NSRegularExpression(pattern: "^【([^】]{2,40})】", options: []),
          let match = regex.firstMatch(in: content, options: [], range: range),
          match.numberOfRanges >= 2,
          let r = Range(match.range(at: 1), in: content) else {
        return ""
    }

    return String(content[r])
}

private func toEpochSeconds(_ input: Any?) -> Int {
    guard let input else { return 0 }

    if let n = input as? NSNumber {
        let d = n.doubleValue
        if d > 1e12 { return Int(d / 1000) }
        if d > 1e9 { return Int(d) }
    }

    let text = anyString(input).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return 0 }

    if text.allSatisfy({ $0.isNumber }) {
        if text.count > 10 {
            return Int(text.prefix(10)) ?? 0
        }
        return Int(text) ?? 0
    }

    let normalized = text.replacingOccurrences(of: "-", with: "/")
    let fmts = [
        "yyyy/MM/dd HH:mm:ss",
        "yyyy/MM/dd HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy/MM/dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss"
    ]

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone.current

    for f in fmts {
        formatter.dateFormat = f
        if let date = formatter.date(from: normalized) {
            return Int(date.timeIntervalSince1970)
        }
    }

    if let date = ISO8601DateFormatter().date(from: text) {
        return Int(date.timeIntervalSince1970)
    }

    return 0
}

private func formatTime(_ epoch: Int) -> String {
    guard epoch > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(epoch))
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.timeZone = TimeZone.current
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

private func anyString(_ value: Any?) -> String {
    guard let value else { return "" }
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return String(describing: value)
}

private func anyInt(_ value: Any?) -> Int {
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String { return Int(s) ?? 0 }
    return 0
}

private func intString(_ value: Any?) -> String {
    let s = anyString(value).trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return "" }
    if s.allSatisfy({ $0.isNumber }) { return s }
    if let d = Double(s), d.isFinite {
        if d > 1e12 { return String(Int(d / 1000)) }
        if d > 0 { return String(Int(d)) }
    }
    return s
}

private extension String {
    var nonEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
