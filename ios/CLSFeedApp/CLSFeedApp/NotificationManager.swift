import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    static let keywordCategoryID = "app.keywordAlert.category"

    private init() {
        configureFeedbackActions()
    }

    func configureFeedbackActions() {
        let tooFrequent = UNNotificationAction(
            identifier: PushFeedbackActionID.tooFrequent,
            title: "太频繁",
            options: []
        )
        let notInterested = UNNotificationAction(
            identifier: PushFeedbackActionID.notInterested,
            title: "不感兴趣",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.keywordCategoryID,
            actions: [tooFrequent, notInterested],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func sendKeywordAlert(for item: TelegraphItem, matchedKeywords: [String]) async {
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        let keywords = matchedKeywords.prefix(2).joined(separator: "、")
        content.title = keywords.isEmpty ? "命中快讯提醒" : "命中关键词：\(keywords)"

        let headline = item.displayTitle.isEmpty
            ? String(item.text.prefix(52))
            : item.displayTitle

        content.body = "[\(item.sourceName)] \(headline)"
        content.sound = .default
        content.categoryIdentifier = Self.keywordCategoryID
        content.userInfo = [
            "uid": item.uid,
            "source": item.source,
            "ctime": item.ctime
        ]

        let req = UNNotificationRequest(
            identifier: "kw-alert-\(item.uid)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.35, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(req)
        } catch {
            // ignore delivery failure
        }
    }
}
