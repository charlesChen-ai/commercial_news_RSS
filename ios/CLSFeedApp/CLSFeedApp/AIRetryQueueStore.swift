import Foundation

struct PendingAIAnalysisJob: Codable, Identifiable, Hashable {
    let id: String
    var item: TelegraphItem
    let createdAt: TimeInterval
    var lastTriedAt: TimeInterval?
    var nextRetryAt: TimeInterval
    var retryCount: Int
    var lastError: String?

    init(
        id: String = UUID().uuidString,
        item: TelegraphItem,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        lastTriedAt: TimeInterval? = nil,
        nextRetryAt: TimeInterval = Date().timeIntervalSince1970,
        retryCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.item = item
        self.createdAt = createdAt
        self.lastTriedAt = lastTriedAt
        self.nextRetryAt = nextRetryAt
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

final class AIRetryQueueStore {
    static let shared = AIRetryQueueStore()

    private let key = "ai.retryQueue"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pendingCount: Int {
        load().count
    }

    func readyJobs(limit: Int = 2, now: Date = Date(), ignoreSchedule: Bool = false) -> [PendingAIAnalysisJob] {
        let nowTS = now.timeIntervalSince1970
        let ordered = load().sorted { lhs, rhs in
            if lhs.nextRetryAt != rhs.nextRetryAt {
                return lhs.nextRetryAt < rhs.nextRetryAt
            }
            return lhs.createdAt < rhs.createdAt
        }
        if ignoreSchedule {
            return Array(ordered.prefix(limit))
        }
        return Array(ordered.filter { $0.nextRetryAt <= nowTS }.prefix(limit))
    }

    @discardableResult
    func enqueue(_ item: TelegraphItem, now: Date = Date()) -> PendingAIAnalysisJob {
        var queue = load()
        let nowTS = now.timeIntervalSince1970

        if let idx = queue.firstIndex(where: { $0.item.uid == item.uid }) {
            queue[idx].item = item
            queue[idx].nextRetryAt = min(queue[idx].nextRetryAt, nowTS)
            queue[idx].lastError = nil
            save(queue)
            return queue[idx]
        }

        let job = PendingAIAnalysisJob(item: item, createdAt: nowTS, nextRetryAt: nowTS)
        queue.append(job)
        save(queue)
        return job
    }

    func markSucceeded(jobID: String) {
        var queue = load()
        queue.removeAll { $0.id == jobID }
        save(queue)
    }

    func markFailed(jobID: String, error: Error, now: Date = Date(), maxRetryCount: Int = 6) {
        var queue = load()
        guard let idx = queue.firstIndex(where: { $0.id == jobID }) else { return }

        queue[idx].retryCount += 1
        queue[idx].lastTriedAt = now.timeIntervalSince1970
        queue[idx].lastError = String(error.localizedDescription.prefix(180))

        if queue[idx].retryCount >= maxRetryCount {
            queue.remove(at: idx)
        } else {
            let delay = retryDelay(for: queue[idx].retryCount)
            queue[idx].nextRetryAt = now.timeIntervalSince1970 + delay
        }

        save(queue)
    }

    func clearAll() {
        defaults.removeObject(forKey: key)
    }

    private func retryDelay(for retryCount: Int) -> TimeInterval {
        let base = 10.0
        let exp = pow(2.0, Double(max(0, retryCount - 1)))
        return min(300.0, base * exp)
    }

    private func load() -> [PendingAIAnalysisJob] {
        guard let data = defaults.data(forKey: key),
              let queue = try? JSONDecoder().decode([PendingAIAnalysisJob].self, from: data) else {
            return []
        }
        return queue
    }

    private func save(_ jobs: [PendingAIAnalysisJob]) {
        if jobs.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(jobs) {
            defaults.set(data, forKey: key)
        }
    }
}
