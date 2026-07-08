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

    private var originalOrigins: [NSWindow.ButtonType: CGPoint] = [:]
    private var observing = false

    func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        repositionButtons(in: window)

        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.repositionButtons(in: window)
            }
        }
    }

    private func repositionButtons(in window: NSWindow) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            // Capture each button's factory origin once, before we ever move
            // it, so the offset is always applied to the same baseline.
            if originalOrigins[type] == nil {
                originalOrigins[type] = button.frame.origin
            }
            guard let base = originalOrigins[type] else { continue }
            // AppKit's y grows upward, so "down" on screen means a smaller y.
            button.setFrameOrigin(CGPoint(x: base.x + Self.insetX, y: base.y - Self.insetDown))
        }
    }
}

enum AppFocus {
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
    }
}
