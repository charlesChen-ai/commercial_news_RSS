import SwiftUI
#if os(iOS)
import UIKit
#endif

struct MainTabView: View {
    init() {
#if os(iOS)
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
#endif
    }

    var body: some View {
        TabView {
            FeedView()
                .tabItem {
                    Label("信息流", systemImage: "newspaper")
                }

            ConsoleView()
                .tabItem {
                    Label("控制台", systemImage: "slider.horizontal.3")
                }
        }
        .tint(.blue)
    }
}
