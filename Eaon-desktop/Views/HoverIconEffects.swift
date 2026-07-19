import SwiftUI

/// Hover-triggered icon micro-interactions for buttons — each mapping
/// exists because the icon's real-world referent actually moves that way
/// (a gear turns, a refresh arrow spins, an external-link arrow leans
/// toward where it points, a pencil tilts to write). Never applied purely
/// for decoration.
///
/// Per Emil Kowalski's frequency rule (animations.dev): a hover effect
/// gets seen tens of times a session, so every motion here stays small
/// (single digits to ~30°, 1-3pt of travel) and fast (150ms) — enough to
/// register as "this responded to me," never enough to read as something
/// you wait out. All three modifiers reuse the app's existing `.uiEaseOut`
/// curve (`Animation+Emil.swift`) rather than inventing a new one, so
/// every hover in the app shares one motion language — the same "unify
/// duration/easing tokens globally" rule this file's own review checklist
/// calls for.
///
/// `.onHover` only ever fires for a real pointer on macOS — there's no
/// touch-hover ambiguity to gate against the way the web needs
/// `@media (hover: hover)` for.

private let iconHoverDuration = 0.15

// MARK: - Base modifiers

/// A small rotation — for icons whose real-world referent physically
/// turns: gears, refresh arrows, a pencil tilting to write, a magnifying
/// glass leaning in. `degrees` should stay well under a full turn.
struct HoverRotateModifier: ViewModifier {
    let degrees: Double
    var anchor: UnitPoint = .center
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isHovered ? degrees : 0), anchor: anchor)
            .animation(.uiEaseOut(duration: iconHoverDuration), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// A small directional lean — for icons that point somewhere (arrows,
/// chevrons, external-link glyphs): the icon nudges a couple points
/// toward where it's pointing, echoing the direction the action actually
/// goes (down for download, up-right for "opens externally," right for
/// "expand/continue").
struct HoverNudgeModifier: ViewModifier {
    let dx: CGFloat
    let dy: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .offset(x: isHovered ? dx : 0, y: isHovered ? dy : 0)
            .animation(.uiEaseOut(duration: iconHoverDuration), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// A small scale bump — the fallback for icons with no natural rotation
/// or direction (folders, files, generic controls, symmetric glyphs like
/// "+" or "x" that don't visibly "move" when rotated a few degrees).
/// Still confirms "this is interactive" without inventing a motion the
/// icon doesn't actually have.
struct HoverLiftModifier: ViewModifier {
    var scale: CGFloat = 1.08
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? scale : 1)
            .animation(.uiEaseOut(duration: iconHoverDuration), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverRotate(_ degrees: Double, anchor: UnitPoint = .center) -> some View {
        modifier(HoverRotateModifier(degrees: degrees, anchor: anchor))
    }

    func hoverNudge(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(HoverNudgeModifier(dx: x, dy: y))
    }

    func hoverLift(_ scale: CGFloat = 1.08) -> some View {
        modifier(HoverLiftModifier(scale: scale))
    }

    /// Maps an SF Symbol name to the hover motion that matches what that
    /// icon actually depicts — the single place this app decides "does
    /// this icon rotate/lean/lift on hover," so the mapping stays
    /// consistent everywhere it's used instead of being re-decided ad hoc
    /// at each call site. Apply only to icons that are themselves a
    /// button's tappable content — never to purely decorative/status
    /// icons, which have nothing to respond to a hover with.
    @ViewBuilder
    func iconHoverEffect(for systemName: String) -> some View {
        switch systemName {
        // Gears turn.
        case "gearshape", "gearshape.fill", "gear", "gearshape.2", "gearshape.2.fill":
            self.hoverRotate(28)

        // Refresh/reload/sync arrows spin clockwise, the direction they draw.
        case "arrow.clockwise", "arrow.clockwise.circle", "arrow.triangle.2.circlepath",
             "arrow.2.circlepath":
            self.hoverRotate(75)

        // Undo/reset arrows spin the other way.
        case "arrow.counterclockwise", "arrow.uturn.backward", "arrow.uturn.left":
            self.hoverRotate(-75)

        // A pencil tilts up onto its point, as if about to write.
        case "pencil", "square.and.pencil", "pencil.circle", "pencil.circle.fill",
             "pencil.line", "highlighter":
            self.hoverRotate(-14, anchor: .bottomLeading)

        // Search leans in for a closer look.
        case "magnifyingglass", "magnifyingglass.circle":
            self.hoverRotate(-12, anchor: .bottomLeading)

        // A trash lid tilts open.
        case "trash", "trash.fill", "trash.circle", "trash.circle.fill":
            self.hoverRotate(-10, anchor: .bottomLeading)

        // A pin tilts as if being pressed in.
        case "pin", "pin.fill", "pin.slash", "pin.slash.fill":
            self.hoverRotate(-18, anchor: .bottom)

        // A bell tilts as if it just rang.
        case "bell", "bell.fill":
            self.hoverRotate(14, anchor: .top)

        // A play triangle leans forward in the direction it points.
        case "play.fill", "play", "play.circle", "play.circle.fill":
            self.hoverNudge(x: 2)

        // External/"opens elsewhere" links lean toward where they're going.
        case "arrow.up.right", "arrow.up.forward", "arrow.up.right.square",
             "arrow.up.forward.app":
            self.hoverNudge(x: 1.5, y: -1.5)

        // Downloads point down, toward disk.
        case "arrow.down.circle", "arrow.down", "arrow.down.circle.fill",
             "square.and.arrow.down", "tray.and.arrow.down":
            self.hoverNudge(y: 2)

        // Sends/uploads point up and out, like a paper airplane taking off.
        case "arrow.up", "arrow.up.circle", "arrow.up.circle.fill", "paperplane",
             "paperplane.fill", "square.and.arrow.up", "tray.and.arrow.up":
            self.hoverNudge(x: 1, y: -2)

        // Disclosure/navigation chevrons lean toward where they'll open —
        // offset only (never rotate): several of these already carry a
        // separate state-driven `.rotationEffect` for expand/collapse, and
        // stacking a second rotation on top would fight it.
        case "chevron.right", "chevron.forward":
            self.hoverNudge(x: 2)
        case "chevron.down":
            self.hoverNudge(y: 2)
        case "chevron.left", "chevron.backward":
            self.hoverNudge(x: -2)
        case "chevron.up":
            self.hoverNudge(y: -2)
        // Eject lifts the disc up and out — same direction the glyph points.
        case "eject", "eject.fill":
            self.hoverNudge(y: -2)
        // A bidirectional picker chevron (up+down together) nudges toward
        // where its popover actually opens — down, on this app's pickers.
        case "chevron.up.chevron.down":
            self.hoverNudge(y: 1.5)

        // Sidebar/panel togglers lean toward the edge they'll open from.
        case "sidebar.left":
            self.hoverNudge(x: -2)
        case "sidebar.right":
            self.hoverNudge(x: 2)

        // Symmetric glyphs (plus, x, sparkle) don't visibly "move" under a
        // few degrees of rotation — a lift reads as responsive instead.
        case "plus", "plus.circle", "plus.circle.fill", "xmark", "xmark.circle",
             "xmark.circle.fill", "sparkle", "sparkles", "star", "star.fill":
            self.hoverLift(1.15)

        default:
            self.hoverLift(1.06)
        }
    }
}
