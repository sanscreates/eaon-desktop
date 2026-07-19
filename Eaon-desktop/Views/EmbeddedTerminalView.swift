import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's `LocalProcessTerminalView` (a real VT100/xterm emulator
/// backed by a pty) so Eaon Code can host an actual, fully interactive
/// terminal running the already-built `eaon-cli` — not a re-implementation
/// of terminal emulation, which is its own deep, dedicated project.
struct EmbeddedTerminalView: NSViewRepresentable {
    /// The command to launch — `EaonCLILauncher.resolve()`'s result, or
    /// nil when eaon-cli couldn't be located (the view then falls back to
    /// the user's own login shell so the pane is never just blank/broken).
    let launch: EaonCLILauncher.Launch?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        if let launch {
            view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment, currentDirectory: launch.currentDirectory)
        } else {
            view.startProcess(executable: "/bin/zsh", args: ["-l"])
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
