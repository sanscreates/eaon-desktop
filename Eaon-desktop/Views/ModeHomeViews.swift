import SwiftUI

// MARK: - Mode switcher

/// Reports one segment's real on-screen frame (in the control's own
/// coordinate space) so the highlight pill can be positioned exactly on top
/// of it — segments aren't equal width ("Agent" vs "Image"), so this can't
/// be computed from index alone.
private struct SegmentFramePreferenceKey: PreferenceKey {
    static var defaultValue: [EaonMode: CGRect] = [:]
    static func reduce(value: inout [EaonMode: CGRect], nextValue: () -> [EaonMode: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Stops `NSWindow.isMovableByWindowBackground` (set on this app's own
/// title-bar-less window — see `WindowChrome`) from hijacking a press-drag
/// meant for the segmented control underneath. Without this, AppKit resolves
/// a mouse-down that lands on plain SwiftUI content as "background," and
/// with background-dragging on, that drags the whole window instead of the
/// pill — and fighting that resolution before it wins is also why the
/// gesture felt like it was landing a beat late. A single real `NSView`
/// covering the control's own bounds, with `mouseDownCanMoveWindow`
/// overridden to `false`, makes AppKit's hit-test resolve to "not
/// draggable" right here, before it ever considers the window.
private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NonMovingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class NonMovingView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// The compact pill that replaced the sidebar's mode rows — lives in the
/// composer bar, next to the attach button. Shown a second time at the top
/// of Eaon Claw's enable card and Image Studio's setup card, since neither
/// of those renders a composer: without it, landing on "Enable Eaon Claw"
/// with nothing configured yet would be a dead end with no way back to Chat.
///
/// Both a tap and a press-and-slide work: a `DragGesture(minimumDistance:
/// 0)` covers both, since a plain tap is just a drag that never moves. While
/// a press is active, the highlight follows the cursor/finger directly and
/// continuously (a real slide, not a jump between fixed slots) — per Emil's
/// "spring-based mouse interaction" guidance, tying a visual straight to
/// live pointer position is what makes a drag feel physically connected to
/// the hand. On release it springs the rest of the way to the nearest
/// segment's exact frame; that's the one moment worth a real animation, so
/// it's a real (if restrained) spring rather than the instant tracking
/// during the drag itself. Kept deliberately subtle everywhere else — this
/// sits in the composer, visible in literally every conversation, so it
/// gets the "seen constantly → shortest and subtlest" treatment throughout.
struct ModeSegmentedControl: View {
    @Environment(\.themeColors) private var colors
    let currentMode: EaonMode
    let onSelect: (EaonMode) -> Void

    @State private var segmentFrames: [EaonMode: CGRect] = [:]
    /// Non-nil only while a press is down — the live X the pill's center is
    /// tracking. nil the rest of the time, when the pill just sits settled
    /// on `currentMode`'s own frame.
    @State private var liveDragX: CGFloat?

    /// Short enough that all four fit comfortably inline — the full name
    /// ("Eaon Claw", "Image Studio") still appears in that mode's own empty
    /// state and enable/setup card, so nothing here is the only place it's
    /// spelled out.
    private func label(for mode: EaonMode) -> String {
        switch mode {
        case .chat: return "Chat"
        case .agent: return "Agent"
        case .claw: return "Claw"
        case .imageStudio: return "Image"
        }
    }

    /// The segment whose center is closest to a given X — used both to pick
    /// the live drag's width/height (a slid pill still borrows whichever
    /// segment it's currently over) and to decide where a release settles.
    private func nearestMode(toX x: CGFloat) -> EaonMode {
        EaonMode.allCases.min { a, b in
            abs((segmentFrames[a]?.midX ?? .infinity) - x) < abs((segmentFrames[b]?.midX ?? .infinity) - x)
        } ?? currentMode
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let pill = pillFrame {
                Capsule()
                    .fill(colors.backgroundChip)
                    .frame(width: pill.width, height: pill.height)
                    .offset(x: pill.minX, y: pill.minY)
            }

            HStack(spacing: 2) {
                ForEach(EaonMode.allCases) { mode in
                    let isActive = mode == currentMode
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(label(for: mode))
                            .font(AppFont.mono(12, weight: .medium))
                    }
                    .foregroundStyle(isActive ? colors.textPrimary : colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SegmentFramePreferenceKey.self,
                                value: [mode: proxy.frame(in: .named("modeSegmentedControl"))]
                            )
                        }
                    )
                }
            }
        }
        .coordinateSpace(name: "modeSegmentedControl")
        .onPreferenceChange(SegmentFramePreferenceKey.self) { segmentFrames = $0 }
        .padding(3)
        .background(Capsule().fill(colors.backgroundInputSecondary))
        .background(WindowDragBlocker())
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("modeSegmentedControl"))
                .onChanged { value in
                    // Deliberately outside withAnimation — this needs to
                    // track the cursor with zero lag every frame, not ease
                    // toward it.
                    liveDragX = value.location.x
                }
                .onEnded { value in
                    let landed = nearestMode(toX: value.location.x)
                    // Both state changes — clearing the live drag AND
                    // committing the new mode — need to land in the SAME
                    // animation transaction, or only half the motion (the
                    // drag-to-nil part) would animate while the mode's own
                    // frame change snapped in instantly right after.
                    withAnimation(.spring(duration: 0.28, bounce: 0.15)) {
                        liveDragX = nil
                        if landed != currentMode {
                            onSelect(landed)
                        }
                    }
                }
        )
    }

    /// Where the pill actually draws right now: the live-tracked X while a
    /// press is down (clamped to whichever segment is currently under it —
    /// so the pill's own width/height stay coherent instead of stretching),
    /// or the settled current segment's real frame otherwise.
    private var pillFrame: CGRect? {
        guard let liveDragX else { return segmentFrames[currentMode] }
        let hovered = nearestMode(toX: liveDragX)
        guard let hoveredFrame = segmentFrames[hovered] else { return nil }
        // The pill's center follows the cursor continuously (the actual
        // "slide" feel); its width/height snap to whichever segment that
        // center currently sits over. Clamped to the real measured extent of
        // all segments (not any one assumed to be "last") so it never drifts
        // past the first/last segment's own bounds.
        let allFrames = segmentFrames.values
        guard let trackMinX = allFrames.map(\.minX).min(), let trackMaxX = allFrames.map(\.maxX).max() else {
            return hoveredFrame
        }
        let clampedMidX = min(max(liveDragX, trackMinX + hoveredFrame.width / 2), trackMaxX - hoveredFrame.width / 2)
        return CGRect(x: clampedMidX - hoveredFrame.width / 2, y: hoveredFrame.minY, width: hoveredFrame.width, height: hoveredFrame.height)
    }
}

// MARK: - Eaon Claw

/// Eaon Claw's surface. Until the capability is enabled it shows a single,
/// honest enable card (this is the "one-click" setup — no hunting through
/// Settings); once enabled it's the normal chat surface with Claw's tools,
/// prompt, and longer agent loop active (all wired in `ChatViewModel` by
/// `currentMode == .claw`).
struct ClawHomeView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable private var claw = DesktopControlStore.shared
    var isSidebarCollapsed: Bool = false
    var onExpandSidebar: () -> Void = {}
    var onOpenProviderSettings: (String) -> Void = { _ in }
    var onModeChange: (EaonMode) -> Void = { _ in }

    var body: some View {
        if claw.isEnabled {
            ChatHomeView(
                viewModel: viewModel,
                isSidebarCollapsed: isSidebarCollapsed,
                onExpandSidebar: onExpandSidebar,
                onOpenProviderSettings: onOpenProviderSettings,
                mode: .claw,
                onModeChange: onModeChange
            )
        } else {
            // The enable card has no composer of its own, so its mode
            // switcher has to do both jobs a normal composer-embedded one
            // splits between ChatComposer and this view's parent: update
            // the view model's real mode AND tell RootView which surface to
            // show. Skipping the first would leave `viewModel.currentMode`
            // out of sync with what's on screen.
            ClawEnableView(onModeChange: { mode in
                viewModel.enterMode(mode)
                onModeChange(mode)
            }) { claw.isEnabled = true }
        }
    }
}

/// The one-click enable card — states plainly what Eaon Claw can do and the
/// guardrails that hold regardless, then enables the capability on a single
/// tap. Full disclosure up front because this is the one mode that reaches
/// out of the app and into the real Mac.
struct ClawEnableView: View {
    @Environment(\.themeColors) private var colors
    /// Not enabled yet, so there's no composer here to switch modes from —
    /// this repeats the same switcher at the top so the screen is never a
    /// dead end.
    var onModeChange: (EaonMode) -> Void = { _ in }
    let onEnable: () -> Void

    private let canDo = [
        ("folder.fill", "Organize files", "List, move, rename, and tidy your files and folders."),
        ("terminal.fill", "Run commands", "Run shell commands to get real work done (no sudo)."),
        ("macwindow", "Drive apps", "Open, quit, and control apps like Safari, Finder, and Notes."),
        ("globe", "Use the browser", "Open pages, read them, and click through multi-step web tasks."),
    ]

    private let guardrails = [
        "Asks before every change — nothing happens without your OK.",
        "Deletes go to the Trash. There's no permanent delete.",
        "No admin/sudo, no touching system files or settings.",
        "Never enters passwords, buys anything, or moves money.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ModeSegmentedControl(currentMode: .claw, onSelect: onModeChange)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)

                Image(systemName: EaonMode.claw.icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(AppearanceSettings.shared.accentColor)
                    .padding(.bottom, 14)

                Text("Eaon Claw")
                    .font(AppFont.mono(30, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 6)

                Text("Let Eaon control your Mac and browser to carry out real, multi-step tasks — the on-device agent, one click away.")
                    .font(AppFont.sans(14))
                    .foregroundStyle(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)

                VStack(spacing: 10) {
                    ForEach(canDo, id: \.0) { icon, title, detail in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon)
                                .font(.system(size: 15))
                                .foregroundStyle(colors.textSecondary)
                                .frame(width: 22)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(AppFont.mono(13, weight: .semibold))
                                    .foregroundStyle(colors.textPrimary)
                                Text(detail)
                                    .font(AppFont.sans(12))
                                    .foregroundStyle(colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: 460)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colors.backgroundChip.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(colors.borderSubtle, lineWidth: 1))
                .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 7) {
                    Text("The rules Eaon Claw always follows")
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundStyle(colors.textTertiary)
                        .padding(.bottom, 2)
                    ForEach(guardrails, id: \.self) { rule in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(colors.textSecondary)
                                .padding(.top, 1)
                            Text(rule)
                                .font(AppFont.sans(12))
                                .foregroundStyle(colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.bottom, 24)

                Button(action: onEnable) {
                    Text("Enable Eaon Claw")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(AppearanceSettings.shared.accentColor))
                }
                .buttonStyle(.plain)

                Text("You can turn this off anytime in Settings → Computer Control.")
                    .font(AppFont.sans(11))
                    .foregroundStyle(colors.textTertiary)
                    .padding(.top, 12)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.backgroundPrimary)
    }
}

// MARK: - Image Studio

/// Image Studio's surface — the normal chat surface with an image model
/// selected (generated images already render as large bubbles there). When
/// no image model is configured yet, it shows setup guidance instead of a
/// dead composer.
struct ImageStudioHomeView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var viewModel: ChatViewModel
    var isSidebarCollapsed: Bool = false
    var onExpandSidebar: () -> Void = {}
    var onOpenProviderSettings: (String) -> Void = { _ in }
    var onModeChange: (EaonMode) -> Void = { _ in }

    var body: some View {
        if viewModel.hasImageModels {
            ChatHomeView(
                viewModel: viewModel,
                isSidebarCollapsed: isSidebarCollapsed,
                onExpandSidebar: onExpandSidebar,
                onOpenProviderSettings: onOpenProviderSettings,
                mode: .imageStudio,
                onModeChange: onModeChange
            )
        } else {
            setupCard
        }
    }

    private var setupCard: some View {
        VStack(spacing: 0) {
            HStack {
                // No composer here either — same reasoning as Eaon Claw's
                // enable card: this switcher must update the real view-model
                // mode itself, not just tell RootView which surface to show.
                ModeSegmentedControl(currentMode: .imageStudio) { mode in
                    viewModel.enterMode(mode)
                    onModeChange(mode)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            VStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
                Text("Image Studio")
                    .font(AppFont.mono(28, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                Text("Generate images from a prompt using a hosted model, a cloud API key, or a local image server. Add one to get started.")
                    .font(AppFont.sans(14))
                    .foregroundStyle(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onOpenProviderSettings("imageProviders")
                } label: {
                    Text("Set up image providers")
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(AppearanceSettings.shared.accentColor))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(colors.backgroundPrimary)
    }
}
