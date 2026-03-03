import SwiftUI

#if os(iOS)
import UIKit
#endif

enum TwitterTheme {
    static let accent = Color(red: 29.0 / 255.0, green: 161.0 / 255.0, blue: 242.0 / 255.0)
    static let divider = Color.black.opacity(0.08)
    static let surface = Color(uiColor: .systemBackground)
    static let subtle = Color(uiColor: .secondarySystemBackground)
}
