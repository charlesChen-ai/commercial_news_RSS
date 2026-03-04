import SwiftUI
#if os(iOS)
import UIKit
#endif

private enum AppShellTab: CaseIterable, Identifiable {
    case home
    case favorites
    case console

    var id: Self { self }

    var icon: String {
        switch self {
        case .home:
            return "house"
        case .favorites:
            return "star"
        case .console:
            return "slider.horizontal.3"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home:
            return "house.fill"
        case .favorites:
            return "star.fill"
        case .console:
            return "slider.horizontal.3"
        }
    }

    var telemetryName: String {
        switch self {
        case .home:
            return "home"
        case .favorites:
            return "favorites"
        case .console:
            return "console"
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var errorCenter: AppErrorCenter
    @StateObject private var homeViewModel = FeedViewModel(scope: "home")
    @StateObject private var favoritesViewModel = FeedViewModel(scope: "favorites")
    @State private var selectedTab: AppShellTab = .home
    @State private var homeButtonTrigger = 0

    init() {
#if os(iOS)
        let twitterBlue = UIColor(
            red: 29.0 / 255.0,
            green: 161.0 / 255.0,
            blue: 242.0 / 255.0,
            alpha: 1
        )
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .systemBackground
        nav.shadowColor = UIColor.separator.withAlphaComponent(0.45)
        nav.titleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]

        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = twitterBlue
#endif
    }

    var body: some View {
        contentView
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .tint(TwitterTheme.accent)
            .overlay(alignment: .top) {
                if let banner = errorCenter.banner {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(banner.title)：\(banner.message)")
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            errorCenter.clearBanner()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(TwitterTheme.surface)
                    .overlay(alignment: .bottom) {
                        Divider()
                            .overlay(TwitterTheme.divider)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .alert(item: $errorCenter.alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("确定")) {
                        errorCenter.clearAlert()
                    }
                )
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { !settings.onboardingCompleted },
                    set: { presented in
                        if !presented {
                            settings.completeOnboarding()
                        }
                    }
                )
            ) {
                OnboardingSetupView()
                    .environmentObject(settings)
            }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .home:
            FeedView(
                isActive: true,
                homeButtonTrigger: homeButtonTrigger,
                viewModel: homeViewModel
            )
        case .favorites:
            FavoritesView(
                isActive: true,
                viewModel: favoritesViewModel
            )
        case .console:
            ConsoleView(isActive: true)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(TwitterTheme.divider)

            HStack {
                ForEach(AppShellTab.allCases) { tab in
                    Button {
                        let started = CFAbsoluteTimeGetCurrent()
                        if tab == .home {
                            homeButtonTrigger += 1
                        }

                        if selectedTab != tab {
                            selectedTab = tab
                            AppHaptics.selection()
                            DispatchQueue.main.async {
                                let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                                AppTelemetryCenter.shared.record(
                                    name: "tab_switch",
                                    value: ms,
                                    meta: ["tab": tab.telemetryName]
                                )
                            }
                            return
                        }

                        if tab == .home {
                            AppHaptics.impact()
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: selectedTab == tab ? tab.selectedIcon : tab.icon)
                                .font(.system(size: 24, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundStyle(selectedTab == tab ? Color.primary : Color.primary.opacity(0.92))
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .background(TwitterTheme.surface)
    }
}
