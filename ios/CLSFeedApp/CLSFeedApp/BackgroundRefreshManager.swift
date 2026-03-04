import Foundation

#if os(iOS)
import BackgroundTasks
import UIKit
import UserNotifications

enum BackgroundRefreshIdentifiers {
    static let appRefreshTask = "com.chaos.CLSFeedApp.feed-refresh"
    static let apnsDeviceTokenKey = "app.apnsDeviceToken"
    static let apnsRegistrationSuppressedKey = "app.apnsRegistrationSuppressed"
    static let apnsRegistrationSuppressedReasonKey = "app.apnsRegistrationSuppressedReason"
    static let apnsRegistrationSuppressedUntilKey = "app.apnsRegistrationSuppressedUntil"
}

struct BackgroundRefreshOutcome {
    let fetchResult: UIBackgroundFetchResult
    let success: Bool
    let newItemCount: Int
    let deliveredAlerts: Int
    let errorMessage: String?
}

struct BackgroundDiagnosticsSnapshot: Codable, Hashable {
    var lastRefreshAttemptAt: Date?
    var lastRefreshSuccessAt: Date?
    var lastRefreshReason: String
    var lastRefreshResult: String
    var lastNewItemCount: Int
    var lastDeliveredAlerts: Int
    var lastError: String
    var lastRemotePushAt: Date?
    var lastDeviceSyncAttemptAt: Date?
    var lastDeviceSyncSuccessAt: Date?
    var lastDeviceSyncError: String
    var lastDeviceSyncBaseURL: String

    static let empty = BackgroundDiagnosticsSnapshot(
        lastRefreshAttemptAt: nil,
        lastRefreshSuccessAt: nil,
        lastRefreshReason: "",
        lastRefreshResult: "",
        lastNewItemCount: 0,
        lastDeliveredAlerts: 0,
        lastError: "",
        lastRemotePushAt: nil,
        lastDeviceSyncAttemptAt: nil,
        lastDeviceSyncSuccessAt: nil,
        lastDeviceSyncError: "",
        lastDeviceSyncBaseURL: ""
    )
}

private enum BackgroundDiagnosticsStore {
    private static let key = "app.backgroundDiagnostics.v1"
    private static let queue = DispatchQueue(label: "cls.background.diagnostics")

    static func read(defaults: UserDefaults = .standard) -> BackgroundDiagnosticsSnapshot {
        queue.sync {
            readUnsafe(defaults: defaults)
        }
    }

    static func markRefreshStart(reason: String, defaults: UserDefaults = .standard) {
        update(defaults: defaults) { snapshot in
            snapshot.lastRefreshAttemptAt = Date()
            snapshot.lastRefreshReason = reason
        }
    }

    static func markRefreshOutcome(reason: String, outcome: BackgroundRefreshOutcome, defaults: UserDefaults = .standard) {
        update(defaults: defaults) { snapshot in
            snapshot.lastRefreshReason = reason
            snapshot.lastRefreshResult = fetchResultText(outcome.fetchResult)
            snapshot.lastNewItemCount = outcome.newItemCount
            snapshot.lastDeliveredAlerts = outcome.deliveredAlerts
            snapshot.lastError = outcome.errorMessage ?? ""
            if outcome.success {
                snapshot.lastRefreshSuccessAt = Date()
            }
        }
        AppTelemetryCenter.shared.record(
            name: "bg_refresh",
            value: Double(outcome.newItemCount),
            meta: [
                "reason": reason,
                "result": fetchResultText(outcome.fetchResult),
                "success": outcome.success ? "1" : "0",
                "alerts": "\(outcome.deliveredAlerts)"
            ]
        )
    }

    static func markRemotePushReceived(defaults: UserDefaults = .standard) {
        update(defaults: defaults) { snapshot in
            snapshot.lastRemotePushAt = Date()
        }
    }

    static func markDeviceSyncStart(baseURL: String, defaults: UserDefaults = .standard) {
        update(defaults: defaults) { snapshot in
            snapshot.lastDeviceSyncAttemptAt = Date()
            snapshot.lastDeviceSyncBaseURL = baseURL
        }
    }

    static func markDeviceSyncSuccess(defaults: UserDefaults = .standard) {
        update(defaults: defaults) { snapshot in
            snapshot.lastDeviceSyncSuccessAt = Date()
            snapshot.lastDeviceSyncError = ""
        }
    }

    static func markDeviceSyncFailure(_ error: String, defaults: UserDefaults = .standard) {
        update(defaults: defaults) { snapshot in
            snapshot.lastDeviceSyncError = error
        }
        AppTelemetryCenter.shared.record(
            name: "device_sync_error",
            meta: ["message": String(error.prefix(120))]
        )
    }

    static func clearDeviceSyncFailure(defaults: UserDefaults = .standard) {
        update(defaults: defaults) { snapshot in
            snapshot.lastDeviceSyncError = ""
        }
    }

    private static func update(defaults: UserDefaults = .standard, _ mutate: (inout BackgroundDiagnosticsSnapshot) -> Void) {
        queue.sync {
            var snapshot = readUnsafe(defaults: defaults)
            mutate(&snapshot)
            if let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: key)
            }
        }
    }

    private static func readUnsafe(defaults: UserDefaults = .standard) -> BackgroundDiagnosticsSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(BackgroundDiagnosticsSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    private static func fetchResultText(_ result: UIBackgroundFetchResult) -> String {
        switch result {
        case .newData:
            return "newData"
        case .noData:
            return "noData"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown"
        }
    }
}

actor BackgroundFeedUpdater {
    static let shared = BackgroundFeedUpdater()

    private let persistence = FeedPersistenceStore(scope: "home")
    private var inFlight = false

    func refresh(reason: String) async -> BackgroundRefreshOutcome {
        if inFlight {
            return BackgroundRefreshOutcome(fetchResult: .noData, success: true, newItemCount: 0, deliveredAlerts: 0, errorMessage: nil)
        }
        inFlight = true
        defer { inFlight = false }

        if Task.isCancelled {
            return BackgroundRefreshOutcome(fetchResult: .failed, success: false, newItemCount: 0, deliveredAlerts: 0, errorMessage: "task_cancelled")
        }

        let snapshot = AppSettings.backgroundSnapshot()
        guard snapshot.autoRefreshEnabled else {
            return BackgroundRefreshOutcome(fetchResult: .noData, success: true, newItemCount: 0, deliveredAlerts: 0, errorMessage: nil)
        }
        guard !snapshot.selectedSources.isEmpty else {
            return BackgroundRefreshOutcome(fetchResult: .noData, success: true, newItemCount: 0, deliveredAlerts: 0, errorMessage: nil)
        }

        do {
            let previous = persistence.loadState()
            let previousUIDs = Set(previous.latestItems.map(\.uid))
            var requestCursor = normalizedCursor(previous.latestCursor)
            let response: TelegraphResponse

            do {
                response = try await APIClient.shared.fetchTelegraph(
                    baseURL: snapshot.effectiveServerBaseURL,
                    limit: 120,
                    sources: snapshot.selectedSources,
                    cursor: requestCursor
                )
            } catch {
                if requestCursor != nil, isInvalidCursorError(error) {
                    requestCursor = nil
                    persistence.saveCursor(nil)
                    response = try await APIClient.shared.fetchTelegraph(
                        baseURL: snapshot.effectiveServerBaseURL,
                        limit: 120,
                        sources: snapshot.selectedSources,
                        cursor: nil
                    )
                } else {
                    throw error
                }
            }

            if Task.isCancelled {
                return BackgroundRefreshOutcome(fetchResult: .failed, success: false, newItemCount: 0, deliveredAlerts: 0, errorMessage: "task_cancelled")
            }

            let fetchedItems = response.items
            guard !fetchedItems.isEmpty else {
                return BackgroundRefreshOutcome(fetchResult: .noData, success: true, newItemCount: 0, deliveredAlerts: 0, errorMessage: nil)
            }

            let mergedItems: [TelegraphItem]
            if requestCursor != nil {
                mergedItems = mergeIncrementalItems(fetchedItems, onto: previous.latestItems, cap: 320)
            } else {
                mergedItems = fetchedItems
            }

            persistence.saveLatestItems(mergedItems, limit: 260)
            persistence.saveLastSuccess(Date())
            let nextCursor =
                normalizedCursor(response.nextCursor)
                ?? mergedItems.first.map { TelegraphCursor.encode(ctime: $0.ctime, uid: $0.uid) }
            persistence.saveCursor(nextCursor)

            let newItems = fetchedItems.filter { !previousUIDs.contains($0.uid) }
            let deliveredAlerts = await deliverKeywordAlertsIfNeeded(
                newItems: newItems,
                keywordAlertEnabled: snapshot.keywordAlertEnabled,
                keywords: snapshot.keywordList,
                existingNotifiedUIDs: previous.notifiedUIDs
            )

            let hasNewData = !newItems.isEmpty || deliveredAlerts > 0
            return BackgroundRefreshOutcome(
                fetchResult: hasNewData ? .newData : .noData,
                success: true,
                newItemCount: newItems.count,
                deliveredAlerts: deliveredAlerts,
                errorMessage: nil
            )
        } catch {
            return BackgroundRefreshOutcome(
                fetchResult: .failed,
                success: false,
                newItemCount: 0,
                deliveredAlerts: 0,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func normalizedCursor(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isInvalidCursorError(_ error: Error) -> Bool {
        if let api = error as? APIClientError,
           case .badServerResponse(let reason) = api {
            let lowered = reason.lowercased()
            return lowered.contains("invalid_cursor") || lowered.contains("cursor_expired")
        }
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains("invalid_cursor") || lowered.contains("cursor_expired")
    }

    private func mergeIncrementalItems(_ incoming: [TelegraphItem], onto existing: [TelegraphItem], cap: Int) -> [TelegraphItem] {
        if incoming.isEmpty { return Array(existing.prefix(cap)) }

        var merged: [TelegraphItem] = []
        merged.reserveCapacity(incoming.count + existing.count)
        merged.append(contentsOf: incoming)
        merged.append(contentsOf: existing)

        var seen = Set<String>()
        var unique: [TelegraphItem] = []
        unique.reserveCapacity(merged.count)
        for item in merged {
            if seen.insert(item.uid).inserted {
                unique.append(item)
            }
        }

        unique.sort {
            if $0.ctime != $1.ctime { return $0.ctime > $1.ctime }
            return $0.uid > $1.uid
        }
        if unique.count > cap {
            return Array(unique.prefix(cap))
        }
        return unique
    }

    private func deliverKeywordAlertsIfNeeded(
        newItems: [TelegraphItem],
        keywordAlertEnabled: Bool,
        keywords: [String],
        existingNotifiedUIDs: Set<String>
    ) async -> Int {
        guard keywordAlertEnabled, !keywords.isEmpty, !newItems.isEmpty else { return 0 }

        var notifiedUIDs = existingNotifiedUIDs
        var sent = 0

        for item in newItems {
            if Task.isCancelled { break }
            if notifiedUIDs.contains(item.uid) { continue }

            let hits = matchedKeywords(for: item, keywords: keywords)
            if hits.isEmpty { continue }

            await NotificationManager.shared.sendKeywordAlert(for: item, matchedKeywords: hits)
            notifiedUIDs.insert(item.uid)
            sent += 1

            if sent >= 2 {
                break
            }
        }

        if sent > 0 {
            _ = persistence.saveUIDSet(notifiedUIDs, bucket: .notified, limit: 1200)
        }
        return sent
    }

    private func matchedKeywords(for item: TelegraphItem, keywords: [String]) -> [String] {
        let haystack = "\(item.title) \(item.text)".lowercased()
        var out: [String] = []
        out.reserveCapacity(2)

        for keyword in keywords {
            if haystack.contains(keyword) {
                out.append(keyword)
            }
            if out.count >= 2 {
                break
            }
        }
        return out
    }
}

@MainActor
final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()

    private var didRegisterBGTask = false
    private var lastDeviceSyncAttemptAt = Date.distantPast

    private init() {}

    nonisolated static func diagnosticsSnapshot() -> BackgroundDiagnosticsSnapshot {
        BackgroundDiagnosticsStore.read()
    }

    nonisolated static func isAPNsRegistrationSuppressed(defaults: UserDefaults = .standard) -> Bool {
        let now = Date().timeIntervalSince1970
        let until = defaults.object(forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedUntilKey) as? Double ?? 0
        if defaults.bool(forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedKey), until > now {
            return true
        }
        if defaults.bool(forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedKey) {
            defaults.set(false, forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedKey)
            defaults.removeObject(forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedReasonKey)
            defaults.removeObject(forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedUntilKey)
        }
        return false
    }

    nonisolated static func apnsSuppressionMessage(defaults: UserDefaults = .standard) -> String {
        guard isAPNsRegistrationSuppressed(defaults: defaults) else { return "" }
        let reason = defaults.string(forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedReasonKey) ?? ""
        switch reason {
        case "missing_entitlement", "register_failed_no_entitlement":
            return "当前签名不支持 APNs（免费签名常见），已自动关闭远程推送注册。"
        default:
            return "远程推送注册已自动关闭。"
        }
    }

    func configure(application: UIApplication) {
        registerBackgroundTaskIfNeeded()
        updateAppRefreshScheduleFromSettings()
        if Self.isAPNsRegistrationSuppressed() {
            return
        }
        syncDeviceRegistrationIfPossible()
        application.registerForRemoteNotifications()
    }

    func registerBackgroundTaskIfNeeded() {
        guard !didRegisterBGTask else { return }

        didRegisterBGTask = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundRefreshIdentifiers.appRefreshTask,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefreshTask(task)
        }
    }

    func updateAppRefreshScheduleFromSettings() {
        let snapshot = AppSettings.backgroundSnapshot()
        if snapshot.autoRefreshEnabled {
            scheduleAppRefresh(after: max(10 * 60, snapshot.refreshInterval * 6))
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefreshIdentifiers.appRefreshTask)
        }
    }

    func scheduleAppRefresh(after delay: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefreshIdentifiers.appRefreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(5 * 60, delay))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("BG schedule failed: \(error.localizedDescription)")
            #endif
        }
    }

    func performLegacyFetch() async -> UIBackgroundFetchResult {
        BackgroundDiagnosticsStore.markRefreshStart(reason: "legacy-fetch")
        let outcome = await BackgroundFeedUpdater.shared.refresh(reason: "legacy-fetch")
        BackgroundDiagnosticsStore.markRefreshOutcome(reason: "legacy-fetch", outcome: outcome)
        return outcome.fetchResult
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard isSilentPushPayload(userInfo) else { return .noData }
        BackgroundDiagnosticsStore.markRemotePushReceived()
        BackgroundDiagnosticsStore.markRefreshStart(reason: "silent-push")
        let outcome = await BackgroundFeedUpdater.shared.refresh(reason: "silent-push")
        BackgroundDiagnosticsStore.markRefreshOutcome(reason: "silent-push", outcome: outcome)
        return outcome.fetchResult
    }

    func persistDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        setAPNsRegistrationSuppressed(false)
        UserDefaults.standard.set(token, forKey: BackgroundRefreshIdentifiers.apnsDeviceTokenKey)
        syncDeviceRegistrationIfPossible()
    }

    func handleAPNsRegistrationFailure(_ error: Error) {
        let message = error.localizedDescription
        if Self.isLikelyEntitlementFailure(message) {
            setAPNsRegistrationSuppressed(
                true,
                reason: "register_failed_no_entitlement",
                holdoff: 24 * 3600
            )
            #if DEBUG
            print("APNs registration skipped: \(message)")
            #endif
            return
        }

        BackgroundDiagnosticsStore.markDeviceSyncFailure("apns_register_failed: \(message)")
        #if DEBUG
        print("APNs registration failed: \(message)")
        #endif
    }

    func syncDeviceRegistrationIfPossible() {
        guard !Self.isAPNsRegistrationSuppressed() else { return }

        let now = Date()
        if now.timeIntervalSince(lastDeviceSyncAttemptAt) < 12 {
            return
        }
        lastDeviceSyncAttemptAt = now

        let token = UserDefaults.standard.string(forKey: BackgroundRefreshIdentifiers.apnsDeviceTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return }

        Task.detached(priority: .utility) {
            let snapshot = AppSettings.backgroundSnapshot()
            guard !snapshot.effectiveServerBaseURL.hasPrefix("app://local") else { return }
            BackgroundDiagnosticsStore.markDeviceSyncStart(baseURL: snapshot.effectiveServerBaseURL)
            do {
                try await APIClient.shared.registerDeviceToken(
                    baseURL: snapshot.effectiveServerBaseURL,
                    token: token,
                    snapshot: snapshot
                )
                BackgroundDiagnosticsStore.markDeviceSyncSuccess()
            } catch {
                BackgroundDiagnosticsStore.markDeviceSyncFailure(error.localizedDescription)
            }
        }
    }

    private func handleAppRefreshTask(_ task: BGAppRefreshTask) {
        updateAppRefreshScheduleFromSettings()

        let worker = Task {
            BackgroundDiagnosticsStore.markRefreshStart(reason: "bg-app-refresh")
            let outcome = await BackgroundFeedUpdater.shared.refresh(reason: "bg-app-refresh")
            BackgroundDiagnosticsStore.markRefreshOutcome(reason: "bg-app-refresh", outcome: outcome)
            task.setTaskCompleted(success: outcome.success)
        }

        task.expirationHandler = {
            worker.cancel()
        }
    }

    private func isSilentPushPayload(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = userInfo["aps"] as? [String: Any] else { return false }

        if let value = aps["content-available"] as? Int {
            return value == 1
        }
        if let value = aps["content-available"] as? NSNumber {
            return value.intValue == 1
        }
        return false
    }

    private func setAPNsRegistrationSuppressed(_ suppressed: Bool, reason: String = "", holdoff: TimeInterval = 0) {
        let defaults = UserDefaults.standard
        defaults.set(suppressed, forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedKey)
        if suppressed {
            defaults.set(reason, forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedReasonKey)
            defaults.set(
                Date().timeIntervalSince1970 + max(3600, holdoff),
                forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedUntilKey
            )
            defaults.removeObject(forKey: BackgroundRefreshIdentifiers.apnsDeviceTokenKey)
            BackgroundDiagnosticsStore.clearDeviceSyncFailure()
        } else {
            defaults.removeObject(forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedReasonKey)
            defaults.removeObject(forKey: BackgroundRefreshIdentifiers.apnsRegistrationSuppressedUntilKey)
        }
    }

    private nonisolated static func isLikelyEntitlementFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("aps-environment")
            || lowered.contains("no valid")
            || lowered.contains("entitlement")
            || lowered.contains("3010")
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.configureFeedbackActions()
        BackgroundRefreshManager.shared.configure(application: application)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundRefreshManager.shared.updateAppRefreshScheduleFromSettings()
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let result = await BackgroundRefreshManager.shared.performLegacyFetch()
            completionHandler(result)
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let result = await BackgroundRefreshManager.shared.handleRemoteNotification(userInfo: userInfo)
            completionHandler(result)
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        BackgroundRefreshManager.shared.persistDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        BackgroundRefreshManager.shared.handleAPNsRegistrationFailure(error)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        guard actionID == PushFeedbackActionID.tooFrequent || actionID == PushFeedbackActionID.notInterested else {
            completionHandler()
            return
        }

        let source = response.notification.request.content.userInfo["source"] as? String
        NotificationCenter.default.post(
            name: .pushFeedbackActionReceived,
            object: nil,
            userInfo: [
                "actionID": actionID,
                "source": source ?? ""
            ]
        )
        completionHandler()
    }
}
#endif
