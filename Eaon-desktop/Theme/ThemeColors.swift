import SwiftUI

/// The single fixed brand accent, used only for actual brand identity (the
/// logo mark/wordmark) — everyday UI chrome is monochrome by default, matching
/// the target ChatGPT-style look, so this is deliberately *not* the app's
/// general-purpose interactive color anymore. It's still offered as one of
/// several selectable options in Appearance settings.
enum AquaBrand {
    static let accent = Color(hex: "#F17455")
}

struct ThemeColors: Equatable {
    let backgroundPrimary: Color
    let backgroundSidebar: Color
    let backgroundElevated: Color
    let backgroundPopover: Color
    let backgroundInput: Color
    let backgroundInputSecondary: Color
    let backgroundCode: Color
    let backgroundCodeHeader: Color
    let backgroundChip: Color
    let backgroundChipSecondary: Color
    let backgroundChart: Color
    let backgroundOverlay: Color
    let backgroundHover: Color
    let backgroundSelected: Color
    let backgroundSubtle: Color

    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textCode: Color

    let borderSubtle: Color
    let borderMedium: Color

    let userBubble: Color
    let shadowColor: Color
    let destructive: Color
    /// Restrained hyperlink tone for inline text links — kept neutral rather
    /// than the brand orange, since everyday chrome is monochrome by default.
    let link: Color

    func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return backgroundSelected }
        if isHovered { return backgroundHover }
        return .clear
    }

    static func forScheme(_ scheme: ColorScheme) -> ThemeColors {
        scheme == .dark ? .dark : .light
    }

    // ChatGPT-desktop-style neutrals: a warm dark charcoal stage with a
    // slightly *darker* sidebar receding behind it (not lighter), and
    // popovers/inputs a shade lighter than the stage so they read as
    // "sitting on top" of it.
    static let dark = ThemeColors(
        backgroundPrimary: Color(hex: "#212121"),
        backgroundSidebar: Color(hex: "#171717"),
        backgroundElevated: Color(hex: "#2F2F2F"),
        backgroundPopover: Color(hex: "#2F2F2F"),
        backgroundInput: Color(hex: "#2F2F2F"),
        backgroundInputSecondary: Color(hex: "#3A3A3A"),
        backgroundCode: Color(hex: "#0D0D0D"),
        backgroundCodeHeader: Color(hex: "#2A2A2A"),
        backgroundChip: Color(hex: "#2F2F2F"),
        backgroundChipSecondary: Color(hex: "#3A3A3A"),
        backgroundChart: Color(hex: "#2A2A2A"),
        backgroundOverlay: Color.black.opacity(0.6),
        backgroundHover: Color.white.opacity(0.06),
        backgroundSelected: Color.white.opacity(0.11),
        backgroundSubtle: Color.white.opacity(0.06),
        textPrimary: Color(hex: "#ECECEC"),
        textSecondary: Color(hex: "#B4B4B4"),
        textTertiary: Color(hex: "#8E8E9C"),
        textCode: Color(hex: "#ECECEC"),
        borderSubtle: Color.white.opacity(0.10),
        borderMedium: Color.white.opacity(0.16),
        userBubble: Color(hex: "#2F2F2F"),
        shadowColor: Color.black.opacity(0.5),
        destructive: Color(hex: "#FF6467"),
        link: Color(hex: "#5B9BFF")
    )

    static let light = ThemeColors(
        backgroundPrimary: Color(hex: "#FFFFFF"),
        backgroundSidebar: Color(hex: "#F9F9F9"),
        backgroundElevated: Color(hex: "#FFFFFF"),
        backgroundPopover: Color(hex: "#FFFFFF"),
        backgroundInput: Color(hex: "#FFFFFF"),
        backgroundInputSecondary: Color(hex: "#F5F5F5"),
        backgroundCode: Color(hex: "#F5F5F5"),
        backgroundCodeHeader: Color(hex: "#EDEDED"),
        backgroundChip: Color(hex: "#F5F5F5"),
        backgroundChipSecondary: Color(hex: "#E5E5E5"),
        backgroundChart: Color(hex: "#F5F5F5"),
        backgroundOverlay: Color.black.opacity(0.3),
        backgroundHover: Color.black.opacity(0.045),
        backgroundSelected: Color.black.opacity(0.07),
        backgroundSubtle: Color.black.opacity(0.045),
        textPrimary: Color(hex: "#0D0D0D"),
        textSecondary: Color(hex: "#5D5D5D"),
        textTertiary: Color(hex: "#8E8E9C"),
        textCode: Color(hex: "#1F2328"),
        borderSubtle: Color.black.opacity(0.08),
        borderMedium: Color.black.opacity(0.14),
        userBubble: Color(hex: "#F4F4F4"),
        shadowColor: Color.black.opacity(0.10),
        destructive: Color(hex: "#E7000B"),
        link: Color(hex: "#2563EB")
    )
}

private struct ThemeColorsKey: EnvironmentKey {
    static let defaultValue = ThemeColors.dark
}

extension EnvironmentValues {
    var themeColors: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }
}

extension View {
    func themed(_ colors: ThemeColors) -> some View {
        environment(\.themeColors, colors)
    }
}
