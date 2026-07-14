import Foundation

/// The app's top-level modes, selected in the sidebar. A mode is a
/// *capability context*: it decides which tools the model is offered, which
/// teaching blocks go into the system prompt, and how long the agent loop is
/// allowed to run — all in `ChatViewModel`. The chat surface itself is shared
/// across all three (they're all conversational). Image generation is its
/// own independent capability (see `ChatViewModel.imageModels`) reachable by
/// picking an image model from the regular model picker in any mode — it
/// isn't gated behind a dedicated mode of its own.
///
/// Deliberately not tied to any one screen — `ChatViewModel.currentMode`
/// persists across launches, and the sidebar reflects it.
enum EaonMode: String, CaseIterable, Identifiable {
    /// Plain conversation. Web search and connected plugins still apply if
    /// the user turned them on, but no code execution and no device control.
    case chat
    /// The coding agent: writes real source files to the user's Mac, runs
    /// them, reads the output, and iterates until they work — the
    /// Claude-Code-style loop. A Sandboxed/Auto toggle (Shift+Tab) controls
    /// whether it confirms each command or runs them automatically.
    case agent
    /// Eaon Claw — the on-device agent. Controls this actual Mac: files,
    /// shell, apps, and the browser, to carry out real multi-step tasks.
    /// The powerful one; off until explicitly enabled.
    case claw

    var id: String { rawValue }

    /// Full label for the sidebar row.
    var title: String {
        switch self {
        case .chat: return "Chat"
        case .agent: return "Agent"
        case .claw: return "Eaon Claw"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .agent: return "hammer.fill"
        case .claw: return "cursorarrow.click.2"
        }
    }

    /// One-line description shown under the mode's own empty state.
    var blurb: String {
        switch self {
        case .chat: return "Just talk — ask anything."
        case .agent: return "Build, run, and debug real code on your Mac."
        case .claw: return "Let Eaon control your Mac and browser to get real tasks done."
        }
    }

    /// The composer placeholder, matched to what the mode is for.
    var composerPlaceholder: String {
        switch self {
        case .chat: return "Message Eaon…"
        case .agent: return "Describe what to build…"
        case .claw: return "Tell Eaon Claw what to do on your Mac…"
        }
    }

    /// True for the mode that drives the real device — the only one gated
    /// behind an explicit, disclosed opt-in.
    var isDeviceControl: Bool { self == .claw }
}
