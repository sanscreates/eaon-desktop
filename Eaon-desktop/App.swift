import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        activateApp()
        // Registers the bundled Plex fonts before any view can ask for them
        // — AppFont also self-registers lazily on first use, so this is a
        // belt-and-suspenders call to avoid any first-render flash rather
        // than something the fonts strictly depend on.
        AppFonts.registerIfNeeded()
        // Forces the bundled curated-model JSON to load and validate right
        // now, at launch — rather than lazily whenever a user first opens
        // the Models tab — so a bad entry (missing file, bad JSON, an
        // unrecognized brand string) crashes immediately and obviously
        // during any normal test pass, not quietly later.
        Task { @MainActor in
            _ = LocalAIManager.curatedOllamaModels
        }
        // Background update check — shows the "New Version" card only when
        // a genuinely newer, non-snoozed release exists; silent otherwise
        // (including when the update server is unreachable).
        Task { @MainActor in
            await UpdateChecker.shared.checkOnLaunch()
        }
        // Silent, same as above — a stale/expired plugin token shouldn't
        // greet the user with an error before they've asked for anything,
        // it should just leave that Plugins row showing "Connect" again.
        Task { @MainActor in
            await MCPConnectionStore.shared.reconnectAllAtLaunch()
        }
        // Restarts the local API server if it was left on last session —
        // `applySettings()` reads `LocalAPIServerStore.isEnabled` itself,
        // so this is a no-op when the user never turned it on.
        Task { @MainActor in
            LocalAPIServer.shared.applySettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        activateApp()
    }

    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct EaonDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 800, minHeight: 600)
                .background(AppWindowActivator())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
        }

        // A real, separate app window (not a modal sheet, not the system
        // browser) for viewing a model's actual page — one per distinct URL;
        // opening the same URL twice brings the existing pop-up forward
        // instead of duplicating it, which is `WindowGroup(for:)`'s default
        // behavior.
        WindowGroup("Model Page", for: URL.self) { $url in
            if let url {
                ModelBrowserWindow(url: url)
            }
        }
        .defaultSize(width: 920, height: 720)
    }
}

/// Brings the Aqua Chat window to the front and makes it the key window for keyboard input.
struct AppWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        Self.pollForWindow(view: view, attempts: 0)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply on every SwiftUI update, inside an async hop so the view is
        // actually attached to its window by the time we read `.window`.
        DispatchQueue.main.async {
            if let window = nsView.window ?? NSApp.windows.first(where: { $0.isVisible }) {
                WindowChrome.shared.apply(to: window)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The window backing the SwiftUI scene often isn't attached (or visible)
    /// at the instant the representable is made, so poll briefly until it is.
    static func pollForWindow(view: NSView, attempts: Int) {
        DispatchQueue.main.async {
            if let window = view.window ?? NSApp.windows.first(where: { $0.isVisible }) {
                NSApp.activate(ignoringOtherApps: true)
                WindowChrome.shared.apply(to: window)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else if attempts < 80 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    pollForWindow(view: view, attempts: attempts + 1)
                }
            }
        }
    }
}

/// Owns the window-chrome customizations: full-size content (so the sidebar
/// card can reach the top) and a rightward/downward nudge of the traffic-light
/// controls so they sit inset on the floating card rather than jammed into the
/// corner. Re-applies on resize, and remembers each button's original origin
/// so repeated calls don't compound the offset.
final class WindowChrome {
    static let shared = WindowChrome()

    /// How far to nudge the traffic lights from their default corner
    /// position. The downward nudge centers them on the sidebar's 50pt
    /// header band, so they sit on the same line as the header's icons —
    /// matching the reference where lights and header controls share a row.
    static let insetX: CGFloat = 18
    static let insetDown: CGFloat = 21

    /// Width of the resized titlebar container — just enough to cover the
    /// three nudged lights plus hover padding, deliberately NOT the full
    /// window width: the taller strip must not sit over (and steal events
    /// from) real content beside the lights, like the sidebar header's own
    /// buttons.
    private static let containerWidth: CGFloat = 100

    private var originalOrigins: [NSWindow.ButtonType: CGPoint] = [:]
    private var originalContainerHeight: CGFloat?
    private var observing = false

    func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        repositionButtons(in: window)

        if !observing {
            observing = true
            // Resize is when AppKit re-lays-out the titlebar to factory
            // positions; key/main changes redraw the lights and can do the
            // same, so re-apply on all of them. didChangeScreen is the one
            // that matters for *dragging*: moving the window to a display
            // with a different scale factor or menu-bar height makes AppKit
            // redo the titlebar's internal layout using its own factory
            // math, silently undoing this class's container resize/button
            // nudge — the buttons (and the container's hidden decoration
            // view) revert to stock positions until something else
            // happened to re-trigger this method. That reversion is what
            // read as "things go half off the window" after a drag: right
            // on a single display, wrong the moment the window crosses
            // onto a differently-scaled one.
            for name: Notification.Name in [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didMoveNotification,
            ] {
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.repositionButtons(in: window)
                }
            }
        }
    }

    private func repositionButtons(in window: NSWindow) {
        // In fullscreen the system owns the buttons (they live in the
        // auto-revealing menubar strip) — moving them there breaks them.
        guard !window.styleMask.contains(.fullScreen) else { return }

        // A moved button stays fully VISIBLE outside its parent's frame
        // (the titlebar doesn't clip drawing) but hover tracking and
        // clicks only land on the part still inside the parent — moving
        // the lights 21pt below a 28pt-tall titlebar container left a
        // ~1pt clickable sliver at their top edge. So the container has
        // to move/grow with them: extend its height by the downward
        // nudge, keeping the buttons at the same factory offset from its
        // (now lower) bottom edge — identical on-screen spot, but fully
        // inside the hit-testable area.
        if let anyButton = window.standardWindowButton(.closeButton),
           let container = anyButton.superview?.superview,
           let themeFrame = container.superview {
            if originalContainerHeight == nil, container.frame.height > 0 {
                originalContainerHeight = container.frame.height
            }
            if let baseHeight = originalContainerHeight {
                let height = baseHeight + Self.insetDown
                container.frame = CGRect(
                    x: 0,
                    y: themeFrame.bounds.height - height,
                    width: Self.containerWidth,
                    height: height
                )
            }

            // The container holds an _NSTitlebarDecorationView (verified by
            // dumping the live hierarchy) that draws the system's rounded
            // titlebar decoration sized to the container — full-width it's
            // invisible against the window edge, but shrunk to the 100pt
            // frame above and nudged down over the sidebar it renders as a
            // stray rounded outline floating over the content. Hidden by
            // matching the class name, since the class is private; done
            // inside this notification-driven method (not just once)
            // because AppKit can re-show it on resize/key changes.
            for subview in container.subviews
            where String(describing: type(of: subview)).contains("Decoration") {
                subview.isHidden = true
            }
        }

        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            // Capture each button's factory origin once, before we ever move
            // it, so the offset is always applied to the same baseline.
            if originalOrigins[type] == nil {
                originalOrigins[type] = button.frame.origin
            }
            guard let base = originalOrigins[type] else { continue }
            // No explicit downward nudge here anymore: the container's
            // bottom edge itself moved down by insetDown, so keeping the
            // factory y inside it lands the button insetDown lower on
            // screen — the same place the old code put it, minus the
            // dead hit-area.
            button.setFrameOrigin(CGPoint(x: base.x + Self.insetX, y: base.y))
        }
    }
}

enum AppFocus {
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
    }
}
