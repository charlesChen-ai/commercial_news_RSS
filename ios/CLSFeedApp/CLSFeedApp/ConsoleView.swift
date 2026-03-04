import SwiftUI
#if os(iOS)
import UIKit
import AuthenticationServices
#endif
#if os(macOS)
import AppKit
#endif

private enum ConsoleSection: String, CaseIterable, Identifiable {
    case overview
    case account
    case push
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "总览"
        case .account:
            return "账号"
        case .push:
            return "推送"
        case .ai:
            return "AI"
        }
    }
}

struct ConsoleView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var errorCenter: AppErrorCenter
    @EnvironmentObject private var accountSession: AccountSessionStore
    let isActive: Bool
    @State private var sourceHealth: [SourceHealth] = []
    @State private var sourceHealthError: String?
    @State private var checkingSourceHealth = false
    @State private var sourceCheckedAt: Date?
    @State private var notificationStatusText = "未知"
    @State private var apnsTokenText = "未注册"
    @State private var apnsRegistrationSuppressed = false
    @State private var apnsSuppressionMessage = ""
    @State private var backgroundDiagnostics = BackgroundDiagnosticsSnapshot.empty
    @State private var accountPhoneInput = ""
    @State private var accountCodeInput = ""
    @State private var codeHintText = ""
    @State private var keywordInput = ""
    @State private var pendingJobsCount = 0
    @State private var didInitialLoad = false
    @State private var lastLoadedAt = Date.distantPast
    @State private var selectedSection: ConsoleSection = .overview
    @State private var telemetrySummary: AppTelemetrySummary = .empty
    @State private var todayNoiseStats: FeedNoiseReductionStats = .empty
    @FocusState private var keywordFieldFocused: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        NavigationStack {
            ZStack {
                groupedBackgroundColor
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        sectionSwitcher
                        sectionContent
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                }
                .refreshable {
                    await refreshSourceHealth()
                }
            }
            .navigationTitle("控制台")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .task(id: isActive) {
                guard isActive else { return }
                let shouldReload = !didInitialLoad || Date().timeIntervalSince(lastLoadedAt) > 12
                guard shouldReload else {
                    refreshFeedNoiseStats()
                    return
                }
                didInitialLoad = true
                await reloadConsoleData()
            }
            .onChange(of: settings.aiProvider) { _ in
                settings.applyProviderPreset()
            }
            .onChange(of: settings.serverBaseURL) { _ in
                syncDeviceRegistrationIfNeeded()
                guard isActive else { return }
                Task { await refreshSourceHealth() }
                refreshBackgroundDiagnostics()
            }
            .onChange(of: settings.offlineModeEnabled) { _ in
                syncDeviceRegistrationIfNeeded()
                guard isActive else { return }
                Task { await refreshSourceHealth() }
                refreshBackgroundDiagnostics()
            }
            .onChange(of: settings.selectedSourceCodes) { _ in
                syncDeviceRegistrationIfNeeded()
                guard isActive else { return }
                Task { await refreshSourceHealth() }
                refreshBackgroundDiagnostics()
            }
            .onChange(of: settings.keywordAlertEnabled) { _ in
                syncDeviceRegistrationIfNeeded()
                refreshBackgroundDiagnostics()
            }
            .onChange(of: settings.keywordSubscriptions) { _ in
                syncDeviceRegistrationIfNeeded()
                refreshBackgroundDiagnostics()
            }
            .onChange(of: settings.pushDeliveryMode) { _ in
                syncDeviceRegistrationIfNeeded()
            }
            .onChange(of: settings.pushTradingHoursOnly) { _ in
                syncDeviceRegistrationIfNeeded()
            }
            .onChange(of: settings.pushDoNotDisturbEnabled) { _ in
                syncDeviceRegistrationIfNeeded()
            }
            .onChange(of: settings.pushDoNotDisturbStart) { _ in
                syncDeviceRegistrationIfNeeded()
            }
            .onChange(of: settings.pushDoNotDisturbEnd) { _ in
                syncDeviceRegistrationIfNeeded()
            }
            .onChange(of: settings.pushRateLimitPerHour) { _ in
                syncDeviceRegistrationIfNeeded()
            }
            .onChange(of: settings.pushSourceCodes) { _ in
                syncDeviceRegistrationIfNeeded()
            }
            .onChange(of: settings.sourceMuteUntilByCode) { _ in
                syncDeviceRegistrationIfNeeded()
                guard isActive else { return }
                Task { await refreshSourceHealth() }
            }
            .onChange(of: settings.feedCollapseThreshold) { _ in
                refreshFeedNoiseStats()
            }
            .onChange(of: settings.feedSourcePriorityByCode) { _ in
                refreshFeedNoiseStats()
            }
            .onChange(of: settings.feedUncollapseUIDUntilByUID) { _ in
                refreshFeedNoiseStats()
            }
            .onChange(of: settings.aiRetryQueueEnabled) { _ in
                refreshPendingJobs()
            }
            .onReceive(NotificationCenter.default.publisher(for: .appTelemetryDidUpdate)) { _ in
                telemetrySummary = AppTelemetryCenter.shared.summary()
            }
            .onChange(of: accountSession.authError) { value in
                if let value, !value.isEmpty {
                    errorCenter.showBanner(
                        title: "账号操作失败",
                        message: value,
                        source: "console.account",
                        level: .warning
                    )
                }
            }
            .onChange(of: sourceHealthError) { value in
                if let value, !value.isEmpty {
                    errorCenter.showBanner(
                        title: "信息源状态检查失败",
                        message: value,
                        source: "console.sourceHealth",
                        level: .warning
                    )
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") {
                        keywordFieldFocused = false
                    }
                }
            }
        }
    }

    private var sectionSwitcher: some View {
        Picker("控制台分区", selection: $selectedSection) {
            ForEach(ConsoleSection.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: selectedSection) { section in
            AppTelemetryCenter.shared.record(
                name: "console_section_switch",
                meta: ["section": section.rawValue]
            )
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .overview:
            serviceCard
            backgroundDiagnosticsCard
            sourcePanelCard
            feedQualityCard
            telemetryCard
        case .account:
            accountCard
        case .push:
            pushStrategyCard
            alertCard
        case .ai:
            aiCard
        }
    }

    private var serviceCard: some View {
        settingsCard(title: "服务") {
            HStack {
                Text("自动刷新")
                Spacer()
                Toggle("", isOn: $settings.autoRefreshEnabled)
                    .labelsHidden()
            }

            HStack {
                Text("离线模式")
                Spacer()
                Toggle("", isOn: $settings.offlineModeEnabled)
                    .labelsHidden()
            }

            HStack {
                Text("刷新间隔")
                Spacer()
                Text("\(Int(settings.refreshInterval)) 秒")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.refreshInterval, in: 1...30, step: 1)
            Text(serviceModeText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var accountCard: some View {
        settingsCard(title: "账号与云同步") {
            if accountSession.isLoggedIn {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(accountSession.accountTitle)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("同步状态")
                        Spacer()
                        Text(accountSession.syncStatusText)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(syncStatusColor)
                    }

                    HStack {
                        Text("上次同步")
                        Spacer()
                        Text(dateTimeText(accountSession.lastSyncAt))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if !accountSession.syncMessage.isEmpty {
                        Text(accountSession.syncMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !accountSession.lastSyncError.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(accountSession.lastSyncError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await accountSession.syncNow(using: settings, reason: "manual") }
                        } label: {
                            if accountSession.isSyncing {
                                ProgressView()
                            } else {
                                Text("立即同步")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(accountSession.isSyncing)

                        Button("退出登录") {
                            Task { await accountSession.logout(using: settings) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if !accountSession.lastSyncError.isEmpty {
                            Button("失败重试") {
                                Task { await accountSession.syncNow(using: settings, reason: "retry") }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(accountSession.isSyncing)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    platformTextField("手机号", text: $accountPhoneInput, optimizedForIME: true)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        platformTextField("验证码", text: $accountCodeInput, optimizedForIME: true)
                            .textFieldStyle(.roundedBorder)

                        Button("获取验证码") {
                            Task {
                                let hint = await accountSession.requestPhoneCode(
                                    baseURL: settings.effectiveServerBaseURL,
                                    phone: accountPhoneInput
                                )
                                codeHintText = hint ?? ""
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(accountPhoneInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if !codeHintText.isEmpty {
                        Text("调试验证码：\(codeHintText)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Button("手机号登录") {
                        Task {
                            await accountSession.verifyPhoneCode(
                                using: settings,
                                phone: accountPhoneInput,
                                code: accountCodeInput
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accountPhoneInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

#if os(iOS)
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.email, .fullName]
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 42)
#endif
                }
            }

            Text("已同步：收藏、已读、关键词与来源订阅。登录后会自动恢复云端状态。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pushStrategyCard: some View {
        settingsCard(title: "推送策略中心") {
            Picker("推送模式", selection: $settings.pushDeliveryMode) {
                ForEach(PushDeliveryMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Toggle("仅交易时段推送", isOn: $settings.pushTradingHoursOnly)
            Toggle("免打扰时段", isOn: $settings.pushDoNotDisturbEnabled)

            if settings.pushDoNotDisturbEnabled {
                HStack(spacing: 8) {
                    platformTextField("开始(22:30)", text: $settings.pushDoNotDisturbStart, optimizedForIME: true)
                        .textFieldStyle(.roundedBorder)
                    platformTextField("结束(07:30)", text: $settings.pushDoNotDisturbEnd, optimizedForIME: true)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Text("每小时频控")
                Spacer()
                Text("\(Int(settings.pushRateLimitPerHour)) 条")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.pushRateLimitPerHour, in: 1...20, step: 1)

            Text("预计每天 \(estimatedPushPerDay()) 条（按当前策略）")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("通知支持“太频繁/不感兴趣”反馈，系统会自动降频或临时静音来源。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("来源推送开关")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(NewsSource.allCases) { source in
                HStack {
                    Text(source.displayName)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.isPushSourceEnabled(source) },
                        set: { settings.setPushSource(source, enabled: $0) }
                    ))
                    .labelsHidden()
                }
                if source != NewsSource.allCases.last {
                    Divider()
                }
            }

            Text("高优先级按 A/B 级快讯识别；交易时段按 A 股工作日 09:30-11:30、13:00-15:00。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sourcePanelCard: some View {
        settingsCard(title: "信息源接入与状态") {
            HStack {
                if let sourceCheckedAt {
                    Text("最近检查：\(timeText(sourceCheckedAt))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("尚未检查")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await refreshSourceHealth() }
                } label: {
                    if checkingSourceHealth {
                        ProgressView()
                    } else {
                        Text("立即检查")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                    .disabled(checkingSourceHealth)
            }

            if let sourceHealthError, !sourceHealthError.isEmpty {
                Text(sourceHealthError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            ForEach(NewsSource.allCases) { source in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(source.displayName)
                            .font(.subheadline)

                        Spacer(minLength: 8)

                        sourceStatusBadge(source)

                        Toggle("", isOn: sourceBinding(source))
                            .labelsHidden()
                    }

                    if let muteText = settings.sourceMuteRemainingText(source) {
                        HStack(spacing: 8) {
                            Label(muteText, systemImage: "speaker.slash.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("解除") {
                                settings.unmuteSource(source)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .contextMenu {
                    Button("静音 24 小时", systemImage: "speaker.slash") {
                        settings.muteSource(source, duration: 24 * 3600)
                    }
                    Button("静音 7 天", systemImage: "speaker.slash.fill") {
                        settings.muteSource(source, duration: 7 * 24 * 3600)
                    }
                    if settings.isSourceTemporarilyMuted(source) {
                        Button("取消静音", systemImage: "speaker.wave.2") {
                            settings.unmuteSource(source)
                        }
                    }
                }
                if source != NewsSource.allCases.last {
                    Divider()
                }
            }
        }
    }

    private var backgroundDiagnosticsCard: some View {
        settingsCard(title: "后台同步诊断") {
#if os(iOS)
            HStack {
                Text("最近尝试")
                Spacer()
                Text(dateTimeText(backgroundDiagnostics.lastRefreshAttemptAt))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("最近成功")
                Spacer()
                Text(dateTimeText(backgroundDiagnostics.lastRefreshSuccessAt))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("触发来源")
                Spacer()
                Text(backgroundDiagnostics.lastRefreshReason.isEmpty ? "--" : backgroundDiagnostics.lastRefreshReason)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("结果")
                Spacer()
                Text(backgroundDiagnostics.lastRefreshResult.isEmpty ? "--" : backgroundDiagnostics.lastRefreshResult)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("新增/提醒")
                Spacer()
                Text("\(backgroundDiagnostics.lastNewItemCount) / \(backgroundDiagnostics.lastDeliveredAlerts)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if apnsRegistrationSuppressed {
                Text(apnsSuppressionMessage.isEmpty ? "当前签名不支持 APNs，已自动关闭远程推送相关能力。" : apnsSuppressionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("静默推送收到")
                    Spacer()
                    Text(dateTimeText(backgroundDiagnostics.lastRemotePushAt))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("设备同步")
                    Spacer()
                    Text(dateTimeText(backgroundDiagnostics.lastDeviceSyncSuccessAt))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if !backgroundDiagnostics.lastDeviceSyncBaseURL.isEmpty {
                    Text("同步地址：\(backgroundDiagnostics.lastDeviceSyncBaseURL)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if !backgroundDiagnostics.lastError.isEmpty {
                Text("后台刷新异常：\(backgroundDiagnostics.lastError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if shouldDisplayDeviceSyncError {
                Text("设备同步异常：\(backgroundDiagnostics.lastDeviceSyncError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("刷新诊断面板") {
                refreshBackgroundDiagnostics()
            }
            .buttonStyle(.bordered)
#else
            Text("后台诊断仅在 iOS 端可用。")
                .font(.footnote)
                .foregroundStyle(.secondary)
#endif
        }
    }

    private var aiCard: some View {
        settingsCard(title: "AI 模型") {
            Toggle("失败自动重试队列", isOn: $settings.aiRetryQueueEnabled)

            Picker("提供商", selection: $settings.aiProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)

            Button("应用提供商默认配置") {
                settings.applyProviderPreset()
            }
            .buttonStyle(.bordered)

            platformSecureField("API Key", text: $settings.aiApiKey)
                .textFieldStyle(.roundedBorder)

            platformTextField("API Base", text: $settings.aiApiBase, isURL: true)
                .textFieldStyle(.roundedBorder)

            platformTextField("Model", text: $settings.aiModel)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("待重试任务：\(pendingJobsCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空队列") {
                    AIRetryQueueStore.shared.clearAll()
                    refreshPendingJobs()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(pendingJobsCount == 0)
            }

            Button("重新打开初始化引导") {
                settings.reopenOnboarding()
            }
            .buttonStyle(.bordered)

            Text("API Key 存在 Keychain 中；本地模式下由手机直接调用模型接口。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var feedQualityCard: some View {
        settingsCard(title: "消息质量控制") {
            Text("折叠策略预设")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("折叠策略", selection: qualityPresetBinding) {
                ForEach(FeedQualityPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("今日噪音下降")
                Spacer()
                if todayNoiseStats.rawCount > 0 {
                    Text("\(todayNoiseStats.reducedCount) / \(todayNoiseStats.rawCount)（\(Int((todayNoiseStats.reductionRate * 100).rounded()))%）")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(todayNoiseStats.reducedCount > 0 ? .green : .secondary)
                } else {
                    Text("--")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if todayNoiseStats.rawCount > 0 {
                Text("按当前策略估算：样本 \(todayNoiseStats.rawCount) 条，折叠后 \(todayNoiseStats.clusteredCount) 条。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("重复快讯折叠阈值")
                Spacer()
                Text("\(Int(settings.feedCollapseThreshold))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $settings.feedCollapseThreshold, in: 55...90, step: 1)

            Text(collapseThresholdHintText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("来源权重（影响同事件主版本与同时间排序）")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(NewsSource.allCases) { source in
                HStack {
                    Text(source.displayName)
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { settings.sourcePriorityWeight(source) },
                            set: { settings.setSourcePriority(source, weight: $0) }
                        ),
                        in: -3...3
                    ) {
                        Text(sourcePriorityText(settings.sourcePriorityWeight(source)))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if source != NewsSource.allCases.last {
                    Divider()
                }
            }

            HStack {
                Text("临时不折叠条目")
                Spacer()
                Text("\(settings.feedUncollapseUIDUntilByUID.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !settings.feedUncollapseUIDUntilByUID.isEmpty {
                    Button("清空") {
                        settings.resetUncollapseUIDs()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                Button("恢复默认") {
                    settings.feedCollapseThreshold = Double(FeedQualitySnapshot.default.collapseThreshold)
                    settings.resetSourcePriorityWeights()
                    settings.resetUncollapseUIDs()
                }
                .buttonStyle(.bordered)

                Button("偏激进折叠") {
                    settings.feedCollapseThreshold = 62
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var telemetryCard: some View {
        settingsCard(title: "性能与行为遥测") {
            HStack {
                Text("事件总数")
                Spacer()
                Text("\(telemetrySummary.totalEvents)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Tab 切换均值")
                Spacer()
                Text("\(telemetrySummary.averageTabSwitchMS) ms")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("刷新均值")
                Spacer()
                Text("\(telemetrySummary.averageFeedRefreshMS) ms")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("24h 刷新错误")
                Spacer()
                Text("\(telemetrySummary.refreshErrorCount24h)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(telemetrySummary.refreshErrorCount24h > 0 ? .red : .secondary)
            }

            HStack {
                Text("已插入新消息")
                Spacer()
                Text("\(telemetrySummary.pendingAppliedTotal) 条")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("最近刷新状态")
                Spacer()
                Text(telemetrySummary.lastFeedRefreshState)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("最近事件")
                Spacer()
                Text(dateTimeText(telemetrySummary.lastEventAt))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("刷新指标") {
                    telemetrySummary = AppTelemetryCenter.shared.summary()
                }
                .buttonStyle(.bordered)

                Button("清空指标") {
                    AppTelemetryCenter.shared.clear()
                    telemetrySummary = .empty
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var alertCard: some View {
        settingsCard(title: "订阅提醒") {
            Toggle("关键词命中提醒", isOn: $settings.keywordAlertEnabled)

            HStack(spacing: 8) {
                platformTextField("新增关键词（支持逗号批量）", text: $keywordInput, optimizedForIME: true)
                    .textFieldStyle(.roundedBorder)
                    .focused($keywordFieldFocused)
#if os(iOS)
                    .submitLabel(.done)
#endif
                    .onSubmit {
                        addKeywordsFromInput()
                        keywordFieldFocused = false
                    }

                Button("添加") {
                    addKeywordsFromInput()
                }
                .buttonStyle(.borderedProminent)
                .disabled(keywordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if settings.keywordSubscriptions.isEmpty {
                Text("暂无关键词。添加后可单独启停或删除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(settings.keywordSubscriptions) { sub in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { sub.isEnabled },
                                set: { settings.setKeywordSubscriptionEnabled(sub.id, enabled: $0) }
                            ))
                            .labelsHidden()

                            platformKeywordEditorField(text: keywordBinding(for: sub))
                                .focused($keywordFieldFocused)
#if os(iOS)
                                .submitLabel(.done)
#endif
                                .onSubmit {
                                    keywordFieldFocused = false
                                }

                            Spacer(minLength: 6)

                            Button {
                                settings.removeKeywordSubscription(id: sub.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(tertiaryBackgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            HStack {
                Text("通知权限：\(notificationStatusText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("请求授权") {
                    Task {
                        _ = await NotificationManager.shared.requestAuthorization()
                        await refreshNotificationStatus()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

#if os(iOS)
            if apnsRegistrationSuppressed {
                Text(apnsSuppressionMessage.isEmpty ? "APNs：当前签名不可用，已自动关闭。" : "APNs：\(apnsSuppressionMessage)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("APNs Token：")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(apnsTokenText)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("复制") {
                        guard apnsTokenText != "未注册" else { return }
                        UIPasteboard.general.string = apnsTokenText
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(apnsTokenText == "未注册")
                }
            }
#endif

            Text("仅对“新抓取”且命中关键词的快讯发送本地通知。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(secondaryBackgroundColor)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(TwitterTheme.divider)
        }
    }

    private func sourceBinding(_ source: NewsSource) -> Binding<Bool> {
        Binding(
            get: { settings.isSourceEnabled(source) },
            set: { settings.setSource(source, enabled: $0) }
        )
    }

    @ViewBuilder
    private func sourceStatusBadge(_ source: NewsSource) -> some View {
        let status = sourceHealth.first { $0.source == source.rawValue }
        if let status {
            HStack(spacing: 6) {
                Text(status.ok ? "OK" : "失败")
                    .foregroundStyle(status.ok ? .green : .red)
                Text("\(status.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
        } else {
            Text("--")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var serviceModeText: String {
        if settings.offlineModeEnabled {
            return "运行模式：离线优先（强制本地抓取）"
        }

        let base = settings.effectiveServerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "local" || base.hasPrefix("app://local") {
            return "运行模式：本地抓取（设备直连信息源与模型接口）"
        }
        return "运行模式：代理服务（\(base)）"
    }

    private var syncStatusColor: Color {
        if accountSession.isSyncing {
            return .blue
        }
        if !accountSession.lastSyncError.isEmpty {
            return .red
        }
        if accountSession.lastSyncAt != nil {
            return .green
        }
        return .secondary
    }

    private var qualityPresetBinding: Binding<FeedQualityPreset> {
        Binding(
            get: {
                let threshold = Int(settings.feedCollapseThreshold.rounded())
                if threshold <= 65 { return .highDedupe }
                if threshold >= 82 { return .keepOriginal }
                return .balanced
            },
            set: { preset in
                settings.feedCollapseThreshold = Double(preset.threshold)
                refreshFeedNoiseStats()
            }
        )
    }

    private var collapseThresholdHintText: String {
        let value = Int(settings.feedCollapseThreshold.rounded())
        if value <= 64 {
            return "当前更激进：会把相似快讯更容易折叠到同事件。"
        }
        if value >= 82 {
            return "当前更保守：只在高度相似时折叠，保留更多独立快讯。"
        }
        return "当前均衡：兼顾去重与信息完整度。"
    }

    private func sourcePriorityText(_ value: Int) -> String {
        let clamped = max(-3, min(3, value))
        if clamped == 0 {
            return "0（默认）"
        }
        if clamped > 0 {
            return "+\(clamped)（优先）"
        }
        return "\(clamped)（降权）"
    }

    private func estimatedPushPerDay() -> Int {
        let pushSources = Set(settings.pushSourceCodes)
        let activeSources = settings.selectedSourceCodes.intersection(pushSources)

        var baseCount = 0
        for source in NewsSource.allCases where activeSources.contains(source.rawValue) {
            let sourceCount = sourceHealth.first { $0.source == source.rawValue }?.count ?? 24
            baseCount += max(0, sourceCount)
        }
        if baseCount <= 0 {
            baseCount = 20
        }

        var ratio = 1.0
        switch settings.pushDeliveryMode {
        case .all:
            ratio *= 1
        case .keywordsOnly:
            let keywordFactor = max(0.08, min(0.45, Double(max(1, settings.keywordList.count)) / 12.0))
            ratio *= keywordFactor
        case .highPriorityOnly:
            ratio *= 0.32
        }

        if settings.pushTradingHoursOnly {
            ratio *= 0.45
        }

        let activeHours = estimatedActiveHoursPerDay()
        ratio *= activeHours / 24.0

        let rawEstimate = max(0, Int((Double(baseCount) * ratio).rounded()))
        let hardCap = max(1, Int(settings.pushRateLimitPerHour.rounded())) * Int(max(1, activeHours.rounded()))
        return min(rawEstimate, hardCap)
    }

    private func estimatedActiveHoursPerDay() -> Double {
        guard settings.pushDoNotDisturbEnabled else { return 24 }
        guard let start = parseClock(settings.pushDoNotDisturbStart),
              let end = parseClock(settings.pushDoNotDisturbEnd) else {
            return 24
        }
        let startMinutes = start.hh * 60 + start.mm
        let endMinutes = end.hh * 60 + end.mm

        let quietMinutes: Int
        if endMinutes > startMinutes {
            quietMinutes = endMinutes - startMinutes
        } else if endMinutes < startMinutes {
            quietMinutes = (24 * 60 - startMinutes) + endMinutes
        } else {
            quietMinutes = 24 * 60
        }

        let activeMinutes = max(0, 24 * 60 - quietMinutes)
        return Double(activeMinutes) / 60.0
    }

    private func parseClock(_ text: String) -> (hh: Int, mm: Int)? {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              (0...23).contains(hh),
              (0...59).contains(mm) else {
            return nil
        }
        return (hh, mm)
    }

    private var shouldDisplayDeviceSyncError: Bool {
        guard !apnsRegistrationSuppressed else { return false }
        let message = backgroundDiagnostics.lastDeviceSyncError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        let lowered = message.lowercased()
        if lowered.contains("aps-environment") || lowered.contains("apns_register_failed") {
            return false
        }
        return true
    }

    @MainActor
    private func refreshSourceHealth() async {
        checkingSourceHealth = true
        defer { checkingSourceHealth = false }

        if settings.selectedSources.isEmpty {
            sourceHealth = []
            sourceCheckedAt = Date()
            sourceHealthError = "当前启用信息源均处于临时静音。"
            return
        }

        do {
            let response = try await APIClient.shared.fetchTelegraph(
                baseURL: settings.effectiveServerBaseURL,
                limit: 20,
                sources: settings.selectedSources
            )
            sourceHealth = response.sources ?? []
            sourceHealthError = nil
            sourceCheckedAt = Date()
            lastLoadedAt = Date()
            refreshPendingJobs()
        } catch {
            sourceHealthError = error.localizedDescription
        }
    }

    @MainActor
    private func reloadConsoleData() async {
        await refreshSourceHealth()
        await refreshNotificationStatus()
        refreshAPNsTokenDisplay()
        refreshPendingJobs()
        refreshBackgroundDiagnostics()
        refreshFeedNoiseStats()
        telemetrySummary = AppTelemetryCenter.shared.summary()
        lastLoadedAt = Date()
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func dateTimeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func addKeywordsFromInput() {
        let separators: Set<Character> = [",", "，", ";", "；", " ", "\n", "\t"]
        let chunks = keywordInput
            .split { separators.contains($0) }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !chunks.isEmpty else { return }

        for keyword in chunks {
            _ = settings.addKeywordSubscription(keyword)
        }
        keywordInput = ""
    }

    private func keywordBinding(for sub: KeywordSubscription) -> Binding<String> {
        Binding(
            get: { settings.keywordSubscriptions.first(where: { $0.id == sub.id })?.keyword ?? sub.keyword },
            set: { settings.updateKeywordSubscription(sub.id, keyword: $0) }
        )
    }

    private func refreshPendingJobs() {
        pendingJobsCount = AIRetryQueueStore.shared.pendingCount
    }

    private func refreshFeedNoiseStats() {
        let snapshot = FeedPersistenceStore(scope: "home").loadState().latestItems
        guard !snapshot.isEmpty else {
            todayNoiseStats = .empty
            return
        }

        let calendar = Calendar.current
        let now = Date()
        let todayItems = snapshot.filter { item in
            guard item.ctime > 0 else { return false }
            let itemDate = Date(timeIntervalSince1970: TimeInterval(item.ctime))
            return calendar.isDate(itemDate, inSameDayAs: now)
        }
        let sample = todayItems.isEmpty ? Array(snapshot.prefix(120)) : todayItems
        guard !sample.isEmpty else {
            todayNoiseStats = .empty
            return
        }

        let clustered = TelegraphClusterer.buildClusters(from: sample, quality: settings.feedQualitySnapshot).count
        let rawCount = sample.count
        todayNoiseStats = FeedNoiseReductionStats(
            rawCount: rawCount,
            clusteredCount: clustered,
            reducedCount: max(0, rawCount - clustered)
        )
    }

    #if os(iOS)
    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                return
            }
            let email = credential.email
            let fullName: String?
            if let components = credential.fullName {
                let formatter = PersonNameComponentsFormatter()
                let text = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
                fullName = text.isEmpty ? nil : text
            } else {
                fullName = nil
            }

            Task {
                await accountSession.loginWithApple(
                    using: settings,
                    appleUserID: credential.user,
                    email: email,
                    fullName: fullName
                )
            }
        case .failure(let error):
            accountSession.authError = error.localizedDescription
        }
    }
    #endif

    private func refreshBackgroundDiagnostics() {
#if os(iOS)
        backgroundDiagnostics = BackgroundRefreshManager.diagnosticsSnapshot()
        apnsRegistrationSuppressed = BackgroundRefreshManager.isAPNsRegistrationSuppressed()
        apnsSuppressionMessage = BackgroundRefreshManager.apnsSuppressionMessage()
#else
        backgroundDiagnostics = .empty
        apnsRegistrationSuppressed = false
        apnsSuppressionMessage = ""
#endif
    }

    private func refreshAPNsTokenDisplay() {
#if os(iOS)
        apnsRegistrationSuppressed = BackgroundRefreshManager.isAPNsRegistrationSuppressed()
        apnsSuppressionMessage = BackgroundRefreshManager.apnsSuppressionMessage()
#endif
        if apnsRegistrationSuppressed {
            apnsTokenText = "不可用"
            return
        }
        let token = UserDefaults.standard.string(forKey: "app.apnsDeviceToken")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty {
            apnsTokenText = token
        } else {
            apnsTokenText = "未注册"
        }
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let status = await NotificationManager.shared.authorizationStatus()
        switch status {
        case .authorized:
            notificationStatusText = "已授权"
        case .provisional:
            notificationStatusText = "临时授权"
        case .denied:
            notificationStatusText = "已拒绝"
        case .notDetermined:
            notificationStatusText = "未请求"
        default:
            notificationStatusText = "未知"
        }
    }

    @ViewBuilder
    private func platformTextField(
        _ title: String,
        text: Binding<String>,
        isURL: Bool = false,
        optimizedForIME: Bool = false
    ) -> some View {
#if os(iOS)
        if isURL {
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        } else if optimizedForIME {
            TextField(title, text: text)
                .keyboardType(.default)
        } else {
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
#else
        TextField(title, text: text)
#endif
    }

    @ViewBuilder
    private func platformSecureField(_ title: String, text: Binding<String>) -> some View {
#if os(iOS)
        SecureField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#else
        SecureField(title, text: text)
#endif
    }

    private func platformKeywordEditorField(text: Binding<String>) -> some View {
#if os(iOS)
        return TextField("关键词", text: text)
            .font(.subheadline)
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#else
        return TextField("关键词", text: text)
            .font(.subheadline)
            .textFieldStyle(.plain)
#endif
    }

    private var groupedBackgroundColor: Color {
#if os(iOS)
        return TwitterTheme.surface
#elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
#else
        return Color.gray.opacity(0.08)
#endif
    }

    private var secondaryBackgroundColor: Color {
#if os(iOS)
        return TwitterTheme.surface
#elseif os(macOS)
        return Color(nsColor: .controlBackgroundColor)
#else
        return Color.gray.opacity(0.12)
#endif
    }

    private var tertiaryBackgroundColor: Color {
#if os(iOS)
        return Color(uiColor: .tertiarySystemBackground)
#elseif os(macOS)
        return Color(nsColor: .underPageBackgroundColor)
#else
        return Color.gray.opacity(0.16)
#endif
    }

    private func syncDeviceRegistrationIfNeeded() {
#if os(iOS)
        BackgroundRefreshManager.shared.syncDeviceRegistrationIfPossible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            refreshBackgroundDiagnostics()
        }
#endif
    }
}
