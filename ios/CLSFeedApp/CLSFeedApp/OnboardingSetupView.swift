import SwiftUI

struct OnboardingSetupView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var skipAIForNow = false
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    introCard
                    sourceCard
                    runtimeCard
                    aiCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("初始化设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后") {
                        settings.completeOnboarding()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let validationMessage, !validationMessage.isEmpty {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        finish()
                    } label: {
                        Text("完成并进入应用")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var introCard: some View {
        card(title: "欢迎", subtitle: "先完成关键项，后续都可在控制台修改") {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 选择需要接入的信息源")
                Text("2. 选择 AI 模型提供商并填写 API Key")
                Text("3. 可选开启离线模式与自动重试")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var sourceCard: some View {
        card(title: "信息源", subtitle: "至少启用一个") {
            ForEach(NewsSource.allCases) { source in
                HStack {
                    Text(source.displayName)
                    Spacer()
                    Toggle("", isOn: sourceBinding(source))
                        .labelsHidden()
                }
                if source != NewsSource.allCases.last {
                    Divider()
                }
            }
        }
    }

    private var runtimeCard: some View {
        card(title: "运行模式", subtitle: "离线模式将优先使用设备本地抓取") {
            Toggle("离线模式", isOn: $settings.offlineModeEnabled)
            Toggle("AI 失败自动重试", isOn: $settings.aiRetryQueueEnabled)
            Toggle("自动刷新", isOn: $settings.autoRefreshEnabled)
        }
    }

    private var aiCard: some View {
        card(title: "AI 配置", subtitle: "默认走 OpenAI 兼容接口") {
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

            SecureField("API Key", text: $settings.aiApiKey)
                .textFieldStyle(.roundedBorder)

            TextField("API Base", text: $settings.aiApiBase)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            TextField("Model", text: $settings.aiModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Toggle("稍后再配置 AI", isOn: $skipAIForNow)
                .tint(.orange)

            Text("API Key 会保存到 Keychain。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceBinding(_ source: NewsSource) -> Binding<Bool> {
        Binding(
            get: { settings.isSourceEnabled(source) },
            set: { settings.setSource(source, enabled: $0) }
        )
    }

    private func card<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func finish() {
        validationMessage = nil

        if settings.selectedSourceCodes.isEmpty {
            validationMessage = "请至少启用一个信息源"
            return
        }

        if !skipAIForNow {
            let key = settings.aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = settings.aiApiBase.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)

            if key.isEmpty {
                validationMessage = "请填写 API Key，或勾选“稍后再配置 AI”"
                return
            }
            if base.isEmpty || model.isEmpty {
                validationMessage = "请补全 AI API Base 与 Model"
                return
            }
        }

        settings.completeOnboarding()
        dismiss()
    }
}
