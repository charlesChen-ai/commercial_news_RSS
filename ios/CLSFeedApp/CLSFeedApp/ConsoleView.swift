import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var sourceHealth: [SourceHealth] = []
    @State private var sourceHealthError: String?
    @State private var checkingSourceHealth = false
    @State private var sourceCheckedAt: Date?
    @State private var notificationStatusText = "未知"
    @State private var keywordInput = ""
    @FocusState private var keywordFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        serviceCard
                        sourcePanelCard
                        alertCard
                        aiCard
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
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await refreshSourceHealth()
                await refreshNotificationStatus()
            }
            .onChange(of: settings.aiProvider) { _ in
                settings.applyProviderPreset()
            }
            .onChange(of: settings.serverBaseURL) { _ in
                Task { await refreshSourceHealth() }
            }
            .onChange(of: settings.selectedSourceCodes) { _ in
                Task { await refreshSourceHealth() }
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

    private var serviceCard: some View {
        settingsCard(title: "服务") {
            HStack {
                Text("自动刷新")
                Spacer()
                Toggle("", isOn: $settings.autoRefreshEnabled)
                    .labelsHidden()
            }

            HStack {
                Text("刷新间隔")
                Spacer()
                Text("\(Int(settings.refreshInterval)) 秒")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.refreshInterval, in: 3...30, step: 1)
            Text("服务地址已隐藏，当前使用 App 内置抓取模式。")
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
                HStack(spacing: 10) {
                    Text(source.displayName)
                        .font(.subheadline)

                    Spacer(minLength: 8)

                    sourceStatusBadge(source)

                    Toggle("", isOn: sourceBinding(source))
                        .labelsHidden()
                }
                if source != NewsSource.allCases.last {
                    Divider()
                }
            }
        }
    }

    private var aiCard: some View {
        settingsCard(title: "AI 模型") {
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

            Text("API Key 存在 Keychain 中；本地模式下由手机直接调用模型接口。")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

                            TextField("关键词", text: keywordBinding(for: sub))
                                .font(.subheadline)
                                .textFieldStyle(.plain)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
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
                        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

            Text("仅对“新抓取”且命中关键词的快讯发送本地通知。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
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

    @MainActor
    private func refreshSourceHealth() async {
        checkingSourceHealth = true
        defer { checkingSourceHealth = false }

        do {
            let response = try await APIClient.shared.fetchTelegraph(
                baseURL: settings.serverBaseURL,
                limit: 20,
                sources: settings.selectedSources
            )
            sourceHealth = response.sources ?? []
            sourceHealthError = nil
            sourceCheckedAt = Date()
        } catch {
            sourceHealthError = error.localizedDescription
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
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
}
