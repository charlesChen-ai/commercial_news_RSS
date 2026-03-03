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
