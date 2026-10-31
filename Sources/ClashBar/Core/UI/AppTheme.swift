import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case sage
    case ocean
    case clay
    case graphite

    var id: String {
        self.rawValue
    }

    func palette(isDark: Bool) -> AppThemePalette {
        switch self {
        case .sage:
            AppThemePalette(
                backgroundColors: isDark
                    ? [
                        Color(red: 0.15, green: 0.18, blue: 0.17),
                        Color(red: 0.19, green: 0.21, blue: 0.18),
                        Color(red: 0.13, green: 0.16, blue: 0.17),
                    ]
                    : [
                        Color(red: 0.91, green: 0.93, blue: 0.87),
                        Color(red: 0.86, green: 0.89, blue: 0.81),
                        Color(red: 0.80, green: 0.85, blue: 0.80),
                    ],
                border: isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12),
                accent: isDark
                    ? Color(red: 0.48, green: 0.76, blue: 0.65)
                    : Color(red: 0.20, green: 0.48, blue: 0.38))
        case .ocean:
            AppThemePalette(
                backgroundColors: isDark
                    ? [
                        Color(red: 0.10, green: 0.16, blue: 0.20),
                        Color(red: 0.12, green: 0.22, blue: 0.28),
                        Color(red: 0.10, green: 0.17, blue: 0.22),
                    ]
                    : [
                        Color(red: 0.88, green: 0.93, blue: 0.95),
                        Color(red: 0.82, green: 0.89, blue: 0.93),
                        Color(red: 0.77, green: 0.85, blue: 0.88),
                    ],
                border: isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.11),
                accent: isDark
                    ? Color(red: 0.45, green: 0.76, blue: 0.92)
                    : Color(red: 0.16, green: 0.43, blue: 0.64))
        case .clay:
            AppThemePalette(
                backgroundColors: isDark
                    ? [
                        Color(red: 0.21, green: 0.16, blue: 0.15),
                        Color(red: 0.27, green: 0.20, blue: 0.17),
                        Color(red: 0.20, green: 0.16, blue: 0.17),
                    ]
                    : [
                        Color(red: 0.95, green: 0.90, blue: 0.86),
                        Color(red: 0.92, green: 0.84, blue: 0.78),
                        Color(red: 0.88, green: 0.80, blue: 0.76),
                    ],
                border: isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.11),
                accent: isDark
                    ? Color(red: 0.95, green: 0.63, blue: 0.45)
                    : Color(red: 0.66, green: 0.36, blue: 0.24))
        case .graphite:
            AppThemePalette(
                backgroundColors: isDark
                    ? [
                        Color(red: 0.14, green: 0.15, blue: 0.16),
                        Color(red: 0.19, green: 0.19, blue: 0.20),
                        Color(red: 0.12, green: 0.13, blue: 0.15),
                    ]
                    : [
                        Color(red: 0.89, green: 0.89, blue: 0.88),
                        Color(red: 0.83, green: 0.84, blue: 0.84),
                        Color(red: 0.78, green: 0.80, blue: 0.81),
                    ],
                border: isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.13),
                accent: isDark
                    ? Color(red: 0.52, green: 0.68, blue: 0.75)
                    : Color(red: 0.25, green: 0.39, blue: 0.48))
        }
    }
}

struct AppThemePalette {
    let backgroundColors: [Color]
    let border: Color
    let accent: Color

    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: self.backgroundColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}
