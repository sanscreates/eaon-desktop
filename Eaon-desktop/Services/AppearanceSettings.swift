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

    /// A few basic solids plus `default`. `default` is special: instead of
    /// one flat color, it spreads a whole palette across the app so
    /// different areas each get their own color (see
    /// `AppearanceSettings.defaultAccentPalette` and `accentColor(seed:)`).
    /// Its swatch renders as a multicolor ring rather than a single fill.
    static let all: [AccentColorOption] = [
        .init(id: "default", color: Color(hex: "#3b82f6")), // representative color; real behavior is multicolor
        .init(id: "blue",    color: Color(hex: "#3b82f6")),
        .init(id: "green",   color: Color(hex: "#2d9f4f")),
        .init(id: "orange",  color: Color(hex: "#e8a838")),
        .init(id: "red",     color: Color(hex: "#e03e3e")),
        .init(id: "purple",  color: Color(hex: "#9b59b6")),
        .init(id: "pink",    color: Color(hex: "#e91e90")),
        .init(id: "white",   color: Color(hex: "#FFFFFF")),
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

    /// The vibrant, harmonious set the "Default" accent spreads across the
    /// app — chosen so any two neighbours read as clearly different colors,
    /// and all sit well on both light and dark surfaces.
    static let defaultAccentPalette: [Color] = [
        Color(hex: "#3b82f6"), // blue
        Color(hex: "#2d9f4f"), // green
        Color(hex: "#e8a838"), // orange
        Color(hex: "#9b59b6"), // purple
        Color(hex: "#e91e90"), // pink
        Color(hex: "#e03e3e"), // red
        Color(hex: "#2ec4b6"), // teal
    ]

    /// True when the user has picked "Default" — the multicolor mode. Callers
    /// that place several accent-tinted things in a row (sidebar icons, etc.)
    /// use `accentColor(seed:)` so each gets its own palette color; a solid
    /// choice ignores the seed and stays that one color everywhere.
    var isMulticolorAccent: Bool { accentColorId == "default" }

    /// The single accent color — for one-off controls (a lone Save button, a
    /// toggle). In multicolor mode this is the palette's lead color so those
    /// still look intentional rather than gray.
    var accentColor: Color {
        if isMulticolorAccent { return Self.defaultAccentPalette[0] }
        return AccentColorOption.all.first { $0.id == accentColorId }?.color ?? Self.defaultAccentPalette[0]
    }

    /// The accent for one item in a set — a settings-section icon, a nav
    /// row. In multicolor mode each `seed` maps to its own palette color, so
    /// a column of icons becomes a column of distinct colors; with a solid
    /// accent chosen, every seed returns that same solid.
    func accentColor(seed: Int) -> Color {
        guard isMulticolorAccent else { return accentColor }
        let palette = Self.defaultAccentPalette
        return palette[((seed % palette.count) + palette.count) % palette.count]
    }

    /// A stable seed from any identifier string, so the same section always
    /// gets the same color across launches (not tied to fragile array order).
    func accentColor(seedFrom identifier: String) -> Color {
        accentColor(seed: abs(Self.stableHash(identifier)))
    }

    private static func stableHash(_ string: String) -> Int {
        // djb2 — deterministic across runs, unlike `String.hashValue` which
        // is salted per-process.
        var hash = 5381
        for byte in string.utf8 { hash = (hash &* 33) ^ Int(byte) }
        return hash
    }

    /// The foreground to put on top of a solid `accentColor` fill — every
    /// option is dark/saturated enough for white to read except "white"
    /// itself, which needs a dark foreground instead.
    var onAccentColor: Color {
        accentColorId == "white" ? .black : .white
    }

    /// Fixed "on" color for every switch-style Toggle, independent of the
    /// user's accent color choice — a toggle set to "white" (the default
    /// accent) would otherwise render as a barely-visible pale track. Matches
    /// Apple's own system-green switch color, and the green already used
    /// elsewhere in this app for "on/good" status (installed, fits well).
    static let toggleTint = Color(hex: "#34C759")

    var colorScheme: ColorScheme? {
        theme.colorScheme
    }

    private init() {
        let savedTheme = UserDefaults.standard.string(forKey: "app_theme") ?? AppTheme.dark.rawValue
        self.theme = AppTheme(rawValue: savedTheme) ?? .dark

        let savedFontSize = UserDefaults.standard.string(forKey: "app_font_size") ?? AppFontSize.medium.rawValue
        self.fontSize = AppFontSize(rawValue: savedFontSize) ?? .medium

        self.accentColorId = UserDefaults.standard.string(forKey: "app_accent_color") ?? "white"

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
        accentColorId = "white"
        notificationPosition = .topRight
        showTokenSpeed = true
        coloredUserBubble = false
    }
}
