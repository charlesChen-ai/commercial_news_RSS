import Foundation

enum AppMessageLevel {
    case info
    case warning
    case error
}

struct AppMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let level: AppMessageLevel
    let source: String
    let createdAt: Date
}

@MainActor
final class AppErrorCenter: ObservableObject {
    @Published var banner: AppMessage?
    @Published var alert: AppMessage?

    private var bannerDismissTask: Task<Void, Never>?

    func showBanner(
        title: String,
        message: String,
        source: String,
        level: AppMessageLevel = .error,
        autoDismissAfter: TimeInterval = 4.0
    ) {
        let msg = AppMessage(title: title, message: message, level: level, source: source, createdAt: Date())
        banner = msg

        bannerDismissTask?.cancel()
        if autoDismissAfter > 0 {
            bannerDismissTask = Task { [weak self] in
                let delay = UInt64(autoDismissAfter * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                guard self?.banner?.id == msg.id else { return }
                self?.banner = nil
            }
        }
    }

    func showAlert(title: String, message: String, source: String, level: AppMessageLevel = .error) {
        alert = AppMessage(title: title, message: message, level: level, source: source, createdAt: Date())
    }

    func clearBanner() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        banner = nil
    }

    func clearAlert() {
        alert = nil
    }
}

struct AppTelemetryEvent: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let value: Double?
    let meta: [String: String]
    let timestamp: Double

    var date: Date { Date(timeIntervalSince1970: timestamp) }
}

struct AppTelemetrySummary: Hashable {
    let totalEvents: Int
    let averageTabSwitchMS: Int
    let averageFeedRefreshMS: Int
    let refreshErrorCount24h: Int
    let pendingAppliedTotal: Int
    let lastFeedRefreshState: String
    let lastEventAt: Date?

    static let empty = AppTelemetrySummary(
        totalEvents: 0,
        averageTabSwitchMS: 0,
        averageFeedRefreshMS: 0,
        refreshErrorCount24h: 0,
        pendingAppliedTotal: 0,
        lastFeedRefreshState: "--",
        lastEventAt: nil
    )
}

final class AppTelemetryCenter {
    static let shared = AppTelemetryCenter()

    private let defaults: UserDefaults
    private let storageKey: String
    private let maxEvents: Int
    private let queue = DispatchQueue(label: "cls.telemetry.center")

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "app.telemetry.events.v1",
        maxEvents: Int = 260
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxEvents = max(40, maxEvents)
    }

    func record(name: String, value: Double? = nil, meta: [String: String] = [:]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        queue.async {
            var list = self.loadEventsUnsafe()
            list.append(
                AppTelemetryEvent(
                    id: UUID().uuidString,
                    name: trimmedName,
                    value: value,
                    meta: meta,
                    timestamp: Date().timeIntervalSince1970
                )
            )
            if list.count > self.maxEvents {
                list = Array(list.suffix(self.maxEvents))
            }
            self.saveEventsUnsafe(list)
            NotificationCenter.default.post(name: .appTelemetryDidUpdate, object: nil)
        }
    }

    func recent(limit: Int = 80) -> [AppTelemetryEvent] {
        queue.sync {
            let list = loadEventsUnsafe()
            if limit <= 0 { return list }
            return Array(list.suffix(limit))
        }
    }

    func summary() -> AppTelemetrySummary {
        queue.sync {
            let list = loadEventsUnsafe()
            guard !list.isEmpty else { return .empty }

            let tabSwitch = list.filter { $0.name == "tab_switch" }
            let feedRefresh = list.filter { $0.name == "feed_refresh" }
            let refreshErrors = list.filter { event in
                event.name == "feed_refresh_error" &&
                Date().timeIntervalSince1970 - event.timestamp <= 24 * 3600
            }
            let pendingApplied = list
                .filter { $0.name == "pending_apply" }
                .compactMap(\.value)
                .reduce(0, +)

            let lastFeedRefreshState = feedRefresh.last?.meta["state"] ?? "--"

            return AppTelemetrySummary(
                totalEvents: list.count,
                averageTabSwitchMS: averageMS(tabSwitch),
                averageFeedRefreshMS: averageMS(feedRefresh),
                refreshErrorCount24h: refreshErrors.count,
                pendingAppliedTotal: Int(pendingApplied.rounded()),
                lastFeedRefreshState: lastFeedRefreshState,
                lastEventAt: list.last?.date
            )
        }
    }

    func clear() {
        queue.sync {
            defaults.removeObject(forKey: storageKey)
        }
        NotificationCenter.default.post(name: .appTelemetryDidUpdate, object: nil)
    }

    private func averageMS(_ list: [AppTelemetryEvent]) -> Int {
        let values = list.compactMap(\.value)
        guard !values.isEmpty else { return 0 }
        let avg = values.reduce(0, +) / Double(values.count)
        return Int(avg.rounded())
    }

    private func loadEventsUnsafe() -> [AppTelemetryEvent] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AppTelemetryEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveEventsUnsafe(_ list: [AppTelemetryEvent]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
