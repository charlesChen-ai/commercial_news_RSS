import SwiftUI

@main
struct CLSFeedAppApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var errorCenter = AppErrorCenter()
    @StateObject private var accountSession = AccountSessionStore()
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(settings)
                .environmentObject(errorCenter)
                .environmentObject(accountSession)
#if os(iOS)
                .onChange(of: settings.autoRefreshEnabled) { _ in
                    BackgroundRefreshManager.shared.updateAppRefreshScheduleFromSettings()
                }
                .onChange(of: settings.refreshInterval) { _ in
                    BackgroundRefreshManager.shared.updateAppRefreshScheduleFromSettings()
                }
                .onChange(of: settings.keywordAlertEnabled) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.keywordSubscriptions) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.selectedSourceCodes) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.serverBaseURL) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.offlineModeEnabled) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.pushDeliveryMode) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.pushTradingHoursOnly) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.pushDoNotDisturbEnabled) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.pushDoNotDisturbStart) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.pushDoNotDisturbEnd) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.pushRateLimitPerHour) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.pushSourceCodes) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
                .onChange(of: settings.sourceMuteUntilByCode) { _ in
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
                }
#endif
                .onChange(of: settings.serverBaseURL) { _ in
                    accountSession.startAutoSync(using: settings)
                }
                .onChange(of: settings.offlineModeEnabled) { _ in
                    accountSession.startAutoSync(using: settings)
                }
                .onChange(of: settings.keywordSubscriptions) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "settings-change") }
                }
                .onChange(of: settings.selectedSourceCodes) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "settings-change") }
                }
                .onChange(of: settings.pushDeliveryMode) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "push-strategy-change") }
                }
                .onChange(of: settings.pushTradingHoursOnly) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "push-strategy-change") }
                }
                .onChange(of: settings.pushDoNotDisturbEnabled) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "push-strategy-change") }
                }
                .onChange(of: settings.pushDoNotDisturbStart) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "push-strategy-change") }
                }
                .onChange(of: settings.pushDoNotDisturbEnd) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "push-strategy-change") }
                }
                .onChange(of: settings.pushRateLimitPerHour) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "push-strategy-change") }
                }
                .onChange(of: settings.pushSourceCodes) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "push-strategy-change") }
                }
                .onChange(of: settings.sourceMuteUntilByCode) { _ in
                    guard accountSession.isLoggedIn else { return }
                    Task { await accountSession.syncNow(using: settings, reason: "source-mute-change") }
                }
                .onReceive(NotificationCenter.default.publisher(for: .pushFeedbackActionReceived)) { note in
                    guard let actionID = note.userInfo?["actionID"] as? String else { return }
                    let sourceRaw = note.userInfo?["source"] as? String
                    settings.applyPushFeedbackAction(actionID, sourceRaw: sourceRaw)
#if os(iOS)
                    BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
#endif
                    if accountSession.isLoggedIn {
                        Task { await accountSession.syncNow(using: settings, reason: "push-feedback") }
                    }
                }
                .task {
                    accountSession.startAutoSync(using: settings)
                    if accountSession.isLoggedIn {
                        await accountSession.restoreFromCloud(using: settings)
                    }
                }
#if DEBUG
                .task {
                    await CoreSelfTests.run()
                }
#endif
        }
    }
}
