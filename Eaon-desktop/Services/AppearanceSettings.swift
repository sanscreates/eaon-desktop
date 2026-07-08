import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

enum AppFontSize: String, CaseIterable, Identifiable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    var id: String { rawValue }

    var messageFontSize: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 15
        case .large: return 17
        }
    }

    var uiScale: CGFloat {
        switch self {
        case .small: return 0.9
        case .medium: return 1.0
        case .large: return 1.1
        }
    }
}

enum NotificationPosition: String, CaseIterable, Identifiable {
    case topRight = "Top right"
    case topLeft = "Top left"
    case bottomRight = "Bottom right"
    case bottomLeft = "Bottom left"
    var id: String { rawValue }
}

struct AccentColorOption: Identifiable {
    let id: String
    let color: Color

    static let all: [AccentColorOption] = [
        .init(id: "default", color: Color(hex: "#8E8E9C")),
        .init(id: "aqua",    color: AquaBrand.accent),
        .init(id: "white",   color: Color(hex: "#FFFFFF")),
        .init(id: "red",     color: Color(hex: "#e03e3e")),
        .init(id: "orange",  color: Color(hex: "#e8a838")),
        .init(id: "yellow",  color: Color(hex: "#c4b500")),
        .init(id: "lime",    color: Color(hex: "#55a630")),
        .init(id: "green",   color: Color(hex: "#2d9f4f")),
        .init(id: "mint",    color: Color(hex: "#30b08c")),
        .init(id: "teal",    color: Color(hex: "#2ec4b6")),
        .init(id: "blue",    color: Color(hex: "#3b82f6")),
        .init(id: "indigo",  color: Color(hex: "#5c6bc0")),
        .init(id: "purple",  color: Color(hex: "#9b59b6")),
        .init(id: "pink",    color: Color(hex: "#e91e90")),
    ]
}

@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "app_theme") }
    }

    var fontSize: AppFontSize {
        didSet { UserDefaults.standard.set(fontSize.rawValue, forKey: "app_font_size") }
    }

    var accentColorId: String {
        didSet { UserDefaults.standard.set(accentColorId, forKey: "app_accent_color") }
    }

    var notificationPosition: NotificationPosition {
        didSet { UserDefaults.standard.set(notificationPosition.rawValue, forKey: "app_notification_position") }
    }

    var showTokenSpeed: Bool {
        didSet { UserDefaults.standard.set(showTokenSpeed, forKey: "app_show_token_speed") }
    }

    var coloredUserBubble: Bool {
        didSet { UserDefaults.standard.set(coloredUserBubble, forKey: "app_colored_user_bubble") }
    }

    var accentColor: Color {
        AccentColorOption.all.first { $0.id == accentColorId }?.color ?? AccentColorOption.all[0].color
    }

    /// The foreground to put on top of a solid `accentColor` fill — every
    /// option is dark/saturated enough for white to read except "white"
    /// itself, which needs a dark foreground instead.
    var onAccentColor: Color {
        accentColorId == "white" ? .black : .white
    }

    var colorScheme: ColorScheme? {
        theme.colorScheme
    }

    private init() {
        let savedTheme = UserDefaults.standard.string(forKey: "app_theme") ?? AppTheme.dark.rawValue
        self.theme = AppTheme(rawValue: savedTheme) ?? .dark

        let savedFontSize = UserDefaults.standard.string(forKey: "app_font_size") ?? AppFontSize.medium.rawValue
        self.fontSize = AppFontSize(rawValue: savedFontSize) ?? .medium

        self.accentColorId = UserDefaults.standard.string(forKey: "app_accent_color") ?? "default"

        let savedPos = UserDefaults.standard.string(forKey: "app_notification_position") ?? NotificationPosition.topRight.rawValue
        self.notificationPosition = NotificationPosition(rawValue: savedPos) ?? .topRight

        if UserDefaults.standard.object(forKey: "app_show_token_speed") != nil {
            self.showTokenSpeed = UserDefaults.standard.bool(forKey: "app_show_token_speed")
        } else {
            self.showTokenSpeed = true
        }

        self.coloredUserBubble = UserDefaults.standard.bool(forKey: "app_colored_user_bubble")
    }

    func resetToDefaults() {
        theme = .dark
        fontSize = .medium
        accentColorId = "default"
        notificationPosition = .topRight
        showTokenSpeed = true
        coloredUserBubble = false
    }
}
