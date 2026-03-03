import Foundation

enum TelegraphClusterer {
    static func buildClusters(from items: [TelegraphItem]) -> [TelegraphCluster] {
        if items.isEmpty { return [] }

        var buckets: [[TelegraphItem]] = []
        var bucketSignatures: [String] = []

        for item in items {
            let signature = clusterSignature(for: item)
            var matchedIndex: Int?

            for idx in buckets.indices {
                guard let representative = buckets[idx].first else { continue }
                if isSameEvent(item, representative, signature, bucketSignatures[idx]) {
                    matchedIndex = idx
                    break
                }
            }

            if let idx = matchedIndex {
                buckets[idx].append(item)
            } else {
                buckets.append([item])
                bucketSignatures.append(signature)
            }
        }

        let merged = buckets.map { group -> TelegraphCluster in
            let sorted = group.sorted(by: itemPrioritySort)
            let id = sorted.first?.uid ?? UUID().uuidString
            return TelegraphCluster(id: id, items: sorted)
        }

        return merged.sorted {
            let a = $0.primary
            let b = $1.primary
            if a.ctime != b.ctime { return a.ctime > b.ctime }
            return a.uid > b.uid
        }
    }

    private static func itemPrioritySort(_ lhs: TelegraphItem, _ rhs: TelegraphItem) -> Bool {
        let lc = contentRank(lhs)
        let rc = contentRank(rhs)
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

    private static func contentRank(_ item: TelegraphItem) -> Int {
        let t = sanitizeForRank(item.title)
        let x = sanitizeForRank(item.text)
        if t.isEmpty && x.isEmpty { return 0 }
        let titleScore = min(80, t.count * 2)
        let textScore = min(180, x.count)
        return titleScore + textScore
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

    private static func isSameEvent(_ lhs: TelegraphItem, _ rhs: TelegraphItem, _ lhsSignature: String, _ rhsSignature: String) -> Bool {
        if lhs.ctime > 0, rhs.ctime > 0, abs(lhs.ctime - rhs.ctime) > 2 * 60 * 60 {
            return false
        }

        if lhsSignature == rhsSignature, !lhsSignature.hasPrefix("u:") {
            return true
        }

        let lh = comparableHeadline(for: lhs)
        let rh = comparableHeadline(for: rhs)
        if lh.count >= 10, rh.count >= 10, lh == rh {
            return true
        }

        let lx = normalizeForCluster(lhs.text)
        let rx = normalizeForCluster(rhs.text)
        if lx.count >= 24, rx.count >= 24, String(lx.prefix(32)) == String(rx.prefix(32)) {
            return true
        }

        if lh.count >= 12, rh.count >= 12 {
            let lp = String(lh.prefix(22))
            let rp = String(rh.prefix(22))
            if lp.count >= 12, rp.count >= 12, (lp == rp || lh.hasPrefix(rp) || rh.hasPrefix(lp)) {
                return true
            }
        }

        if lh.count >= 12, rx.count >= 20, rx.hasPrefix(String(lh.prefix(20))) {
            return true
        }
        if rh.count >= 12, lx.count >= 20, lx.hasPrefix(String(rh.prefix(20))) {
            return true
        }

        return false
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
        text
            .lowercased()
            .replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^【[^】]{2,30}】", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^(财联社|新浪财经|华尔街见闻|同花顺|东方财富)(\\d{1,2}月\\d{1,2}日)?电[，,:：\\s]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^[\\p{Han}a-z0-9%]{0,16}电[，,:：\\s]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{Han}a-z0-9%]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeForRank(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[\\u200B\\u200C\\u200D\\u2060\\uFEFF]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
