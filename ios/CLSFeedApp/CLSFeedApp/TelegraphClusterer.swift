import Foundation

enum TelegraphClusterer {
    private struct ClusterBucket {
        var items: [TelegraphItem]
        var signature: String
        var mergeReason: String?
        var mergeScore: Int
        var containsUncollapsible: Bool
    }

    private struct SimilarityResult {
        var score: Int
        var reason: String?
    }

    private static var normalizeCache: [String: String] = [:]
    private static var sanitizeCache: [String: String] = [:]
    private static let cacheQueue = DispatchQueue(label: "cls.cluster.cache")
    private static let cacheLimit = 2800

    static func buildClusters(from items: [TelegraphItem], quality: FeedQualitySnapshot = .default) -> [TelegraphCluster] {
        if items.isEmpty { return [] }

        var buckets: [ClusterBucket] = []
        let threshold = max(55, min(90, quality.collapseThreshold))
        let uncollapseUIDs = quality.uncollapseUIDs

        for item in items {
            let signature = clusterSignature(for: item)
            var matchedIndex: Int?
            var matchedResult: SimilarityResult?

            for idx in buckets.indices {
                guard let representative = buckets[idx].items.first else { continue }
                if uncollapseUIDs.contains(item.uid) || buckets[idx].containsUncollapsible {
                    continue
                }

                let result = similarityScore(
                    item,
                    representative,
                    lhsSignature: signature,
                    rhsSignature: buckets[idx].signature
                )
                if result.score >= threshold {
                    matchedIndex = idx
                    matchedResult = result
                    break
                }
            }

            if let idx = matchedIndex {
                buckets[idx].items.append(item)
                if let matchedResult, matchedResult.score >= buckets[idx].mergeScore {
                    buckets[idx].mergeScore = matchedResult.score
                    buckets[idx].mergeReason = matchedResult.reason
                }
                if uncollapseUIDs.contains(item.uid) {
                    buckets[idx].containsUncollapsible = true
                }
            } else {
                buckets.append(
                    ClusterBucket(
                        items: [item],
                        signature: signature,
                        mergeReason: nil,
                        mergeScore: 0,
                        containsUncollapsible: uncollapseUIDs.contains(item.uid)
                    )
                )
            }
        }

        let merged = buckets.map { bucket -> TelegraphCluster in
            let sorted = bucket.items.sorted { lhs, rhs in
                itemPrioritySort(lhs, rhs, quality: quality)
            }
            let id = sorted.first?.uid ?? UUID().uuidString
            return TelegraphCluster(
                id: id,
                items: sorted,
                mergeReason: bucket.items.count > 1 ? bucket.mergeReason : nil,
                mergeScore: bucket.items.count > 1 ? bucket.mergeScore : 0
            )
        }

        return merged.sorted {
            let a = $0.primary
            let b = $1.primary
            let ap = quality.priority(for: a.source)
            let bp = quality.priority(for: b.source)
            if ap != bp { return ap > bp }
            if a.ctime != b.ctime { return a.ctime > b.ctime }
            return a.uid > b.uid
        }
    }

    private static func itemPrioritySort(_ lhs: TelegraphItem, _ rhs: TelegraphItem, quality: FeedQualitySnapshot) -> Bool {
        let lc = contentRank(lhs, quality: quality)
        let rc = contentRank(rhs, quality: quality)
        if lc != rc { return lc > rc }

        let l = levelRank(lhs.level)
        let r = levelRank(rhs.level)
        if l != r { return l > r }
        if lhs.ctime != rhs.ctime { return lhs.ctime > rhs.ctime }
        return lhs.uid > rhs.uid
    }

    private static func levelRank(_ level: String) -> Int {
        switch level.uppercased() {
        case "A":
            return 3
        case "B":
            return 2
        default:
            return 1
        }
    }

    private static func contentRank(_ item: TelegraphItem, quality: FeedQualitySnapshot) -> Int {
        let t = sanitizeForRank(item.title)
        let x = sanitizeForRank(item.text)
        if t.isEmpty && x.isEmpty { return 0 }
        let titleScore = min(80, t.count * 2)
        let textScore = min(180, x.count)
        let sourceBonus = quality.priority(for: item.source) * 18
        return titleScore + textScore + sourceBonus
    }

    private static func clusterSignature(for item: TelegraphItem) -> String {
        let h = comparableHeadline(for: item)
        if h.count >= 10 {
            return "h:\(String(h.prefix(72)))"
        }

        let x = normalizeForCluster(item.text)
        if x.count >= 18 {
            return "x:\(String(x.prefix(44)))"
        }

        return "u:\(item.uid)"
    }

    private static func similarityScore(
        _ lhs: TelegraphItem,
        _ rhs: TelegraphItem,
        lhsSignature: String,
        rhsSignature: String
    ) -> SimilarityResult {
        if lhs.ctime > 0, rhs.ctime > 0, abs(lhs.ctime - rhs.ctime) > 2 * 60 * 60 {
            return SimilarityResult(score: 0, reason: nil)
        }

        var score = 0
        var reason: String?

        func apply(_ candidate: Int, _ candidateReason: String) {
            if candidate > score {
                score = candidate
                reason = candidateReason
            }
        }

        if lhsSignature == rhsSignature, !lhsSignature.hasPrefix("u:") {
            apply(100, "标题签名一致")
        }

        let lh = comparableHeadline(for: lhs)
        let rh = comparableHeadline(for: rhs)
        let lx = normalizeForCluster(lhs.text)
        let rx = normalizeForCluster(rhs.text)

        if lh.count >= 10, rh.count >= 10, lh == rh {
            apply(96, "标题一致")
        }

        if lx.count >= 24, rx.count >= 24, String(lx.prefix(32)) == String(rx.prefix(32)) {
            apply(90, "正文前缀一致")
        }

        if lh.count >= 12, rh.count >= 12 {
            let lp = String(lh.prefix(22))
            let rp = String(rh.prefix(22))
            if lp.count >= 12, rp.count >= 12, (lp == rp || lh.hasPrefix(rp) || rh.hasPrefix(lp)) {
                apply(82, "标题前缀相近")
            }
        }

        if lh.count >= 12, rx.count >= 20, rx.hasPrefix(String(lh.prefix(20))) {
            apply(76, "标题命中正文")
        }
        if rh.count >= 12, lx.count >= 20, lx.hasPrefix(String(rh.prefix(20))) {
            apply(76, "正文命中标题")
        }

        if lhs.source == rhs.source {
            score += 3
            if reason == nil {
                reason = "同源快讯"
            }
        }

        if lhs.ctime > 0, rhs.ctime > 0 {
            let delta = abs(lhs.ctime - rhs.ctime)
            if delta > 60 * 60 {
                score -= 10
            } else if delta > 20 * 60 {
                score -= 4
            }
        }

        return SimilarityResult(
            score: max(0, min(100, score)),
            reason: reason
        )
    }

    private static func comparableHeadline(for item: TelegraphItem) -> String {
        let t = normalizeForCluster(item.displayTitle)
        if t.count >= 10 {
            return t
        }
        let x = normalizeForCluster(item.text)
        if x.count >= 24 {
            return String(x.prefix(32))
        }
        return x
    }

    private static func normalizeForCluster(_ text: String) -> String {
        cachedNormalized(text)
    }

    private static func sanitizeForRank(_ text: String) -> String {
        cachedSanitized(text)
    }

    private static func cachedNormalized(_ text: String) -> String {
        let key = cacheKey(prefix: "n", text: text)
        if let cached = cacheQueue.sync(execute: { normalizeCache[key] }) {
            return cached
        }
        let output = text
            .lowercased()
            .replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^【[^】]{2,30}】", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^(财联社|新浪财经|华尔街见闻|同花顺|东方财富)(\\d{1,2}月\\d{1,2}日)?电[，,:：\\s]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^[\\p{Han}a-z0-9%]{0,16}电[，,:：\\s]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{Han}a-z0-9%]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cacheQueue.sync {
            if normalizeCache.count > cacheLimit {
                normalizeCache.removeAll(keepingCapacity: true)
            }
            normalizeCache[key] = output
        }
        return output
    }

    private static func cachedSanitized(_ text: String) -> String {
        let key = cacheKey(prefix: "s", text: text)
        if let cached = cacheQueue.sync(execute: { sanitizeCache[key] }) {
            return cached
        }
        let output = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[\\u200B\\u200C\\u200D\\u2060\\uFEFF]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cacheQueue.sync {
            if sanitizeCache.count > cacheLimit {
                sanitizeCache.removeAll(keepingCapacity: true)
            }
            sanitizeCache[key] = output
        }
        return output
    }

    private static func cacheKey(prefix: String, text: String) -> String {
        let head = text.prefix(40)
        let tail = text.suffix(24)
        return "\(prefix)|\(text.count)|\(head)|\(tail)"
    }
}
