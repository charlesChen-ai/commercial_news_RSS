import SwiftUI

@main
struct CLSFeedAppApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var errorCenter = AppErrorCenter()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(settings)
                .environmentObject(errorCenter)
#if DEBUG
                .task {
                    await CoreSelfTests.run()
                }
#endif
        }
    }
}
