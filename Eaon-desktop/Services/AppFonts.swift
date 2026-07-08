import AppKit
import CoreText
import SwiftUI

/// Registers the bundled IBM Plex fonts (SIL Open Font License — see
/// `Resources/Fonts/LICENSE-IBMPlex.txt`) and exposes them through `AppFont`.
///
/// This is a preview of a possible direction, not yet the app's default —
/// only three representative screens (Models, Settings, Chat) use `AppFont`
/// so far. Everywhere else still uses the system font untouched. If this
/// direction sticks, the natural next step is routing the rest of the app
/// through `AppFont` too and retiring the raw `.system(...)` calls.
enum AppFonts {
    /// Real PostScript names, confirmed empirically against the actual
    /// bundled files via Core Text (`Medium`/`SemiBold` abbreviate to
    /// `Medm`/`SmBld` in Plex's own naming — not the obvious guess, so this
    /// was verified rather than assumed).
    private static let files: [(fileName: String, postScriptName: String)] = [
        ("IBMPlexMono-Regular", "IBMPlexMono"),
        ("IBMPlexMono-Medium", "IBMPlexMono-Medm"),
        ("IBMPlexMono-SemiBold", "IBMPlexMono-SmBld"),
        ("IBMPlexMono-Bold", "IBMPlexMono-Bold"),
        ("IBMPlexSans-Regular", "IBMPlexSans"),
        ("IBMPlexSans-Medium", "IBMPlexSans-Medm"),
        ("IBMPlexSans-SemiBold", "IBMPlexSans-SmBld"),
        ("IBMPlexSans-Bold", "IBMPlexSans-Bold"),
    ]

    private static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Eaon-desktop_Eaon-desktop", withExtension: "bundle"),
           let resourceBundle = Bundle(url: url) {
            return resourceBundle
        }
        return Bundle.module
    }()

    private(set) static var isRegistered = false

    /// Registers every bundled Plex file with Core Text so `Font.custom`
    /// can find it by PostScript name — call once, at launch, before any UI
    /// renders. Missing/malformed files are skipped individually rather
    /// than failing the whole app; `AppFont` falls back to the system font
    /// per-style if its specific PostScript name never registered.
    static func registerIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true
        for (fileName, _) in files {
            guard let url = bundle.url(forResource: fileName, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // Already-registered is expected on a second launch path in the
            // same process (e.g. SwiftUI previews) — anything else is worth
            // knowing about during development.
            if let error, (error.takeUnretainedValue() as Error as NSError).code != CTFontManagerError.alreadyRegistered.rawValue {
                print("AppFonts: failed to register \(fileName): \(error.takeUnretainedValue())")
            }
        }
    }
}

/// The mono/sans pair for the Plex preview screens. Falls back to the
/// matching system style if a given weight's file somehow isn't registered
/// — this never renders a missing-font placeholder, worst case it silently
/// reverts to SF for that one call site.
enum AppFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let name = postScriptName(family: "IBMPlexMono", weight: weight) else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(name, size: size)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let name = postScriptName(family: "IBMPlexSans", weight: weight) else {
            return .system(size: size, weight: weight)
        }
        return .custom(name, size: size)
    }

    /// The same Plex Sans, as a raw `NSFont` — for the one spot that isn't
    /// SwiftUI `Text` at all: the composer's `NSTextView`-based editor,
    /// which needs an actual `NSFont` for its `.font` property (and for
    /// measuring wrapped-text height with the same metrics it renders
    /// with). Falls back to the system font exactly like `sans(_:weight:)`.
    static func sansNSFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let fontWeight: Font.Weight = weight == .bold ? .bold : weight == .semibold ? .semibold : weight == .medium ? .medium : .regular
        guard let name = postScriptName(family: "IBMPlexSans", weight: fontWeight),
              let font = NSFont(name: name, size: size) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        return font
    }

    private static func postScriptName(family: String, weight: Font.Weight) -> String? {
        AppFonts.registerIfNeeded()
        switch weight {
        case .bold, .heavy, .black:
            return "\(family)-Bold"
        case .semibold:
            return "\(family)-SmBld"
        case .medium:
            return "\(family)-Medm"
        default:
            return family
        }
    }
}
