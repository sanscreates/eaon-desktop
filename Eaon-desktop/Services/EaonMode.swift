import Foundation

/// The app's four top-level modes, selected in the sidebar. A mode is a
/// *capability context*: it decides which tools the model is offered, which
/// teaching blocks go into the system prompt, and how long the agent loop is
/// allowed to run — all in `ChatViewModel`. The chat surface itself is shared
/// across Chat/Agent/Eaon Claw (they're all conversational); Image Studio is
/// the same surface pointed at image models.
///
/// Deliberately not tied to any one screen — `ChatViewModel.currentMode`
/// persists across launches, and the sidebar reflects it.
enum EaonMode: String, CaseIterable, Identifiable {
    /// Plain conversation. Web search and connected plugins still apply if
    /// the user turned them on, but no code execution and no device control.
    case chat
    /// The coding agent: writes, runs, and iterates on files inside a
    /// contained workspace (never the user's wider filesystem). "Sandboxed"
    /// in the sense that its file tools only touch the conversation's own
    /// workspace, not the whole Mac the way Eaon Claw does.
    case agent
    /// Eaon Claw — the on-device agent. Controls this actual Mac: files,
    /// shell, apps, and the browser, to carry out real multi-step tasks.
    /// The powerful one; off until explicitly enabled.
    case claw
    /// Generate images from a prompt, using an image model (hosted or local).
    case imageStudio

    var id: String { rawValue }

    /// Full label for the sidebar row.
    var title: String {
        switch self {
        case .chat: return "Chat"
        case .agent: return "Agent"
        case .claw: return "Eaon Claw"
        case .imageStudio: return "Image Studio"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .agent: return "hammer.fill"
        case .claw: return "cursorarrow.click.2"
        case .imageStudio: return "wand.and.stars"
        }
    }

    /// One-line description shown under the mode's own empty state.
    var blurb: String {
        switch self {
        case .chat: return "Just talk — ask anything."
        case .agent: return "Build and run code in a sandboxed workspace."
        case .claw: return "Let Eaon control your Mac and browser to get real tasks done."
        case .imageStudio: return "Generate images from a prompt."
        }
    }

    /// The composer placeholder, matched to what the mode is for.
    var composerPlaceholder: String {
        switch self {
        case .chat: return "Message Eaon…"
        case .agent: return "Describe what to build…"
        case .claw: return "Tell Eaon Claw what to do on your Mac…"
        case .imageStudio: return "Describe an image to generate…"
        }
    }

    /// True for the mode that drives the real device — the only one gated
    /// behind an explicit, disclosed opt-in.
    var isDeviceControl: Bool { self == .claw }
}
