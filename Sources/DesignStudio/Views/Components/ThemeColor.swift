import SwiftUI
import AppKit

/// 可选的主题色
enum ThemeColor: String, CaseIterable, Identifiable {
    case system, blue, terracotta, indigo, purple, pink, red, green, teal, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terracotta: "陶土"
        case .system: "跟随系统"
        case .blue: "蓝色"
        case .indigo: "靛蓝"
        case .purple: "紫色"
        case .pink: "粉色"
        case .red: "红色"
        case .green: "绿色"
        case .teal: "青色"
        case .graphite: "石墨"
        }
    }

    var color: Color {
        switch self {
        case .terracotta: Color(hex: "#D97757")
        case .system: Color(nsColor: .controlAccentColor)
        case .blue: Color(hex: "#2F6FEB")
        case .indigo: Color(hex: "#5856D6")
        case .purple: Color(hex: "#9254DE")
        case .pink: Color(hex: "#E0518D")
        case .red: Color(hex: "#E5484D")
        case .green: Color(hex: "#2F9E68")
        case .teal: Color(hex: "#1F9AA8")
        case .graphite: Color(hex: "#6B6F76")
        }
    }
}

/// 全局主题色状态（与 AppSettings.accentTheme 同步）
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    var choice: ThemeColor = .terracotta
}
