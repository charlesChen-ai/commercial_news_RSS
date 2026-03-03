import Foundation

enum RecapGenerator {
    static func generate(items: [TelegraphItem], date: Date = Date()) -> String {
        let sorted = items.sorted { $0.ctime < $1.ctime }
        if sorted.isEmpty {
            return "今日暂无可复盘快讯。"
        }

        let important = sorted.filter { ["A", "B"].contains($0.level.uppercased()) }
        let sourceCount = Dictionary(grouping: sorted, by: { $0.sourceName }).mapValues(\.count)
        let sourceSummary = sourceCount
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\($0.key)\($0.value)" }
            .joined(separator: " / ")

        let hourBuckets = Dictionary(grouping: sorted) { item in
            let h = hourString(item.ctime)
            return h.isEmpty ? "未知时段" : h
        }

        let timeline = sorted.suffix(24).map { item in
            let head = item.displayTitle.isEmpty ? item.text : item.displayTitle
            return "[\(item.time)] \(item.sourceName) \(clip(head, 46))"
        }

        let importantLines = important.suffix(10).map { item in
            let head = item.displayTitle.isEmpty ? item.text : item.displayTitle
            return "- [\(item.time)] \(clip(head, 54))"
        }

        let busyHours = hourBuckets
            .map { (key: $0.key, count: $0.value.count) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.count)" }
            .joined(separator: " / ")

        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd"

        var out: [String] = []
        out.append("【聚合复盘】\(df.string(from: date))")
        out.append("总快讯: \(sorted.count) 条 | 重要快讯: \(important.count) 条")
        if !sourceSummary.isEmpty {
            out.append("来源分布: \(sourceSummary)")
        }
        if !busyHours.isEmpty {
            out.append("时段分布: \(busyHours)")
        }

        if !importantLines.isEmpty {
            out.append("\n重点事件")
            out.append(contentsOf: importantLines)
        }

        out.append("\n时间线")
        out.append(contentsOf: timeline)

        out.append("\n备注: 本复盘由客户端自动汇总，建议结合盘口与公告二次确认。")

        return out.joined(separator: "\n")
    }

    private static func hourString(_ ctime: Int) -> String {
        guard ctime > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ctime))
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:00"
        return f.string(from: date)
    }

    private static func clip(_ text: String, _ max: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= max { return clean }
        return String(clean.prefix(max)) + "…"
    }
}
