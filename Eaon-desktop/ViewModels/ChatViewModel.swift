import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var content: String
    var isUser: Bool
    var timestamp = Date()
    var isError: Bool = false
    var modelId: String?
    var modelName: String?
    var attachments: [MessageAttachment] = []
    var generationStartTime: Date?
    var generationEndTime: Date?
    var generatedTokenCount: Int = 0
    /// Set on synthetic messages that carry automated tool results back to
    /// the agent (sent with the "user" role, rendered as a compact card).
    /// Optional so older persisted messages decode without the key.
    var isToolResult: Bool?
    /// True only when a real pre-flight check (Ollama's `/api/ps`, or
    /// whether a matching llama.cpp/MLX server was already the active
    /// spawned process) confirmed this specific response required a fresh
    /// model load rather than reusing an already-warm one. Optional (like
    /// `isToolResult`) so a message persisted before this field existed
    /// still decodes — Swift's synthesized `Decodable` does NOT fall back
    /// to a non-optional property's default value for a missing key, it
    /// throws, which upstream is swallowed by a `try?` on the *whole*
    /// conversations array — a `Bool = false` here would have silently
    /// dropped every conversation saved before this field existed.
    var wasColdLoad: Bool?
    /// Precise load-only wall-clock time — populated only for llama.cpp/MLX,
    /// where spawning the server and waiting for it to become healthy is a
    /// genuinely separate phase from generation, measured cleanly before the
    /// first token is requested. Left nil for Ollama: its model load happens
    /// inside the same opaque HTTP call as generation, with no way to
    /// isolate the two from the client side — showing a number here would
    /// claim a precision the data doesn't support.
    var coldLoadDurationSeconds: Double?
    /// Real memory footprint of the loaded model, from Ollama's own `/api/ps`
    /// — nil when not applicable (not local, or the backend doesn't expose
    /// this) rather than a guess.
    var localMemoryBytes: Int64?
    /// True only for an assistant message whose whole point IS the image in
    /// `attachments` — not incidental to it, the way a user's uploaded photo
    /// is. Optional (like `isToolResult`/`wasColdLoad`) so older persisted
    /// messages decode fine without this key. Rendering shows this image
    /// large and prominent rather than as a small attachment thumbnail.
    var isGeneratedImage: Bool?
    /// Set on a user message that invoked a skill via `/name` — the
    /// hyphenated skill name, for the small badge shown above the bubble.
    /// `content` itself is already the command-stripped text (see
    /// `ChatViewModel.extractSkillInvocation`), so this is display-only;
    /// nothing re-parses `content` looking for a slash command later.
    /// Optional, like the other flags on this struct, so older persisted
    /// messages decode fine without the key.
    var invokedSkillName: String?
}

/// A single saved conversation, shown in the "Your chats" sidebar list.
struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage]
    var createdAt = Date()
    var updatedAt = Date()
    var hasUnread: Bool = false
    /// The project (folder) this chat belongs to, if any. Optional so older
    /// persisted conversations without this field decode fine as ungrouped.
    var projectId: UUID?
    /// Pinned chats show in their own sidebar section above the date
    /// buckets, regardless of how recently they were touched. Optional
    /// (like `projectId`) rather than a non-optional `Bool = false` — see
    /// `ChatMessage.wasColdLoad`'s doc comment for exactly why a
    /// non-optional default here would silently wipe every older
    /// conversation on decode.
    var isPinned: Bool?

    static func placeholderTitle() -> String { "New chat" }
}

/// A plain folder for grouping chats — just a name, nothing else. No
/// per-project assistant/instructions/knowledge-base concept.
struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date()
}

/// An `eaon:mcp` call awaiting the user's explicit go-ahead — which
/// service, which tool, and its (pretty-printed) JSON arguments, shown by
/// `MCPCallConfirmationDialog` so the decision is informed, not a blind
/// "allow?". See `ChatViewModel.confirmMCPCallIfNeeded(server:tool:argumentsJSON:)`.
struct PendingMCPCall: Equatable {
    let serverDisplayName: String
    let tool: String
    let argumentsJSON: String
}

/// A desktop-control action awaiting the user's go-ahead — a one-line
/// human-readable `summary` ("Move report.pdf → Documents/") plus, for the
/// open-ended tools, the full `detail` (the shell command or AppleScript
/// verbatim). Shown by `DesktopCallConfirmationDialog`.
struct PendingDesktopCall: Equatable {
    let summary: String
    let detail: String?
}

/// The user's answer to a desktop-action prompt. `allowAll` grants the rest
/// of the conversation, mirroring the coding agent's per-chat run approval.
enum DesktopConfirmDecision {
    case allowOnce, allowAll, deny
}

struct APIModelResponse: Codable {
    let data: [APIModel]
}

struct APIModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String?
    let tier: String?
}

@MainActor
@Observable
class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText: String = ""
    var selectedModel: String = ""
    /// The active top-level mode (Chat / Agent / Eaon Claw) — drives which
    /// tools and teaching blocks the model gets and how long the agent loop
    /// may run (see `mergedNativeTools`, `systemPromptHistory`,
    /// `maxAgentSteps`). Persisted so the app reopens in the same mode.
    var currentMode: EaonMode = .chat {
        didSet {
            guard currentMode != oldValue else { return }
            UserDefaults.standard.set(currentMode.rawValue, forKey: Self.currentModeKey)
        }
    }
    /// The coding Agent's permission state, toggled with Shift+Tab:
    /// false = **Sandboxed** (the default — every command is confirmed
    /// before it runs), true = **Auto** (unsandboxed — commands run without
    /// asking). Deliberately NOT persisted: it resets to Sandboxed on every
    /// launch, so a powerful "runs commands without asking" mode is never
    /// silently in effect from a past session. Only consulted in Agent mode.
    var agentAutoRun: Bool = false
    /// Non-nil exactly while the "switch to Auto mode?" confirmation should
    /// be showing — entering Auto (never leaving it) is gated behind an
    /// explicit are-you-sure. See `requestAgentPermissionToggle`.
    var isAskingToEnterAutoMode: Bool = false
    var availableModels: [APIModel] = []
    /// Aqua's hosted image-generation models — fetched separately from
    /// `availableModels` because `AquaSupportedModels` (behind
    /// `apiService.fetchModels()`) is a hand-maintained chat-only allowlist
    /// that excludes them entirely; this reads the live `type == "image"`
    /// field directly instead. See `AquaImageModels`.
    var aquaImageModels: [APIModel] = []
    var isGenerating: Bool = false
    var isLoadingModels = false
    var modelsLoadError: String?
    var activeTypingMessageId: UUID?
    /// Real status text for the in-flight local model load — e.g. "Loading
    /// deepseek-r1:7b into memory…" — set only when a pre-flight check
    /// (Ollama's `/api/ps`, or the spawned-server state for llama.cpp/MLX)
    /// confirms this specific model actually needs to load, and cleared the
    /// moment real content starts arriving. Shown in place of the generic
    /// typing indicator for the local case specifically.
    var loadingStatusText: String?
    /// What the agent is doing right now between visible message content —
    /// running a specific tool, searching the web — for the window where a
    /// step's own text has already finished streaming but the *next* step
    /// hasn't started yet (the real network call is in flight). Nil the
    /// rest of the time. Not tied to any one `ChatMessage`, since nothing
    /// about this phase belongs to a specific message — shown as its own
    /// small transient row at the bottom of the conversation instead.
    var agentActivityText: String?
    var pendingAttachments: [MessageAttachment] = []
    var composerNotice: String?
    /// Non-nil exactly while the run-confirmation dialog should be
    /// showing — the file path the agent wants to execute. See
    /// `confirmRunIfNeeded(path:)`.
    var pendingRunConfirmation: String?
    /// Non-nil exactly while the MCP call-confirmation dialog should be
    /// showing. See `confirmMCPCallIfNeeded(server:tool:argumentsJSON:)`.
    var pendingMCPCallConfirmation: PendingMCPCall?
    /// Non-nil exactly while the desktop-control confirmation dialog should
    /// be showing. See `confirmDesktopCallIfNeeded(tool:arguments:)`.
    var pendingDesktopCallConfirmation: PendingDesktopCall?

    // MARK: - Memory backfill (mining facts from chats that predate turning memory on)

    var isBackfillingMemory = false
    /// A short status line the Memory settings page shows for the
    /// duration of a backfill and its final result — progress while
    /// running, a summary once done. Nil before the first run.
    var memoryBackfillStatus: String?
    private var memoryBackfillCancelRequested = false

    /// All saved conversations, most-recently-updated first when displayed.
    var conversations: [Conversation] = []
    /// The conversation currently open, or nil for a fresh (unsaved) chat.
    var currentConversationId: UUID?
    /// All saved project folders.
    var projects: [Project] = []

    private static let conversationsKey = "aqua_conversations"
    private static let projectsKey = "aqua_projects"
    /// Tags the *next* chat created by `saveMessages()` with a project — set
    /// by `startNewChat(inProject:)`, consumed the moment the first message
    /// actually creates the `Conversation` record.
    private var pendingProjectId: UUID?

    /// Conversations sorted for the sidebar (newest activity first).
    var sortedConversations: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Conversations not filed into any project — what the sidebar's flat
    /// "Chats" list shows. Project chats only ever appear inside their own
    /// folder's disclosure, never mixed into this list.
    var unfiledConversations: [Conversation] {
        sortedConversations.filter { $0.projectId == nil }
    }

    /// Pinned, unfiled chats — shown in their own sidebar section instead
    /// of buried in the date buckets below. Scoped to unfiled chats only,
    /// same as `unfiledConversations`: a chat filed into a project already
    /// lives in that project's own list.
    var pinnedConversations: [Conversation] {
        unfiledConversations.filter { $0.isPinned == true }
    }

    /// `unfiledConversations` minus whatever's already shown in the Pinned
    /// section above it — what the date-bucketed "Chats" list actually
    /// renders.
    var unpinnedUnfiledConversations: [Conversation] {
        unfiledConversations.filter { $0.isPinned != true }
    }

    func togglePinned(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].isPinned = (conversations[index].isPinned == true) ? nil : true
        persistConversations()
    }

    /// Projects sorted newest-first, matching the chat list's convention.
    var sortedProjects: [Project] {
        projects.sorted { $0.createdAt > $1.createdAt }
    }

    /// Chats belonging to a given project, most-recently-updated first.
    func conversations(inProject projectId: UUID) -> [Conversation] {
        conversations.filter { $0.projectId == projectId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Chat-capable models with per-model hiding applied, but *not* filtered
    /// by disabled providers — this is what the model picker browses so a
    /// disabled provider's section stays visible (and re-toggleable) there.
    /// Merges Aqua's catalog with BYOK providers and local models (Ollama /
    /// llama.cpp / MLX).
    var allChatCapableModels: [APIModel] {
        let aquaModels = availableModels
            .filter(\.isChatModel)
            .filter { !ModelPreferencesStore.shared.isHidden($0.id) }
        let customModels = CustomProviderStore.shared.syntheticModels
            .filter { !ModelPreferencesStore.shared.isHidden($0.id) }
        let localModels = LocalAIManager.shared.syntheticModels
            .filter { !ModelPreferencesStore.shared.isHidden($0.id) }
        // Deduplicated because the same model id can arrive from more than
        // one source at once — e.g. a BYOK gateway serving deepseek-v4-flash
        // while Aqua's catalog also lists it. Everything downstream (routing,
        // provider grouping) is a function of the bare id, so both copies
        // land in the same picker group — and duplicate ids inside one
        // ForEach corrupt LazyVStack's layout (the blank-gap /
        // vanishing-rows-on-scroll bug). Collapsing changes no behavior;
        // which copy answers a request was already decided by id alone.
        return Self.deduplicated(aquaModels + customModels + localModels)
    }

    /// The actually-selectable set: `allChatCapableModels` minus anything
    /// from a provider (connection) the user has switched off. Local models
    /// are never gated — no provider owns them to switch off.
    var chatModels: [APIModel] {
        allChatCapableModels.filter { model in
            guard let key = providerKey(forModelId: model.id) else { return true }
            return !ModelPreferencesStore.shared.isProviderDisabled(key)
        }
    }

    /// Which actual provider (connection) serves a model — Aqua's one
    /// connection, or a specific BYOK config — or `nil` for a local model,
    /// which no provider toggle can ever gate. This is the real "provider"
    /// the user means when they say "turn off a provider": Aqua serves many
    /// model companies at once, and a BYOK config is its own connection even
    /// when it serves a company Aqua also serves — so the company itself
    /// (e.g. "Anthropic") is never independently switchable.
    func providerKey(forModelId modelId: String) -> ModelProviderKey? {
        if LocalAIManager.shared.owns(modelId) { return nil }
        if let config = CustomProviderStore.shared.config(owning: modelId) { return .custom(config.id) }
        return .aqua
    }

    /// Image-generation models — Aqua's own hosted ones plus any configured
    /// BYOK/local image connections. Deliberately separate from
    /// `chatModels`/`allChatCapableModels`: image generation is one
    /// request/response with none of the chat-specific machinery (context
    /// window, vision support, tool-calling, conversation history) those
    /// lists exist to support.
    var imageModels: [APIModel] {
        let aqua = aquaImageModels.filter { !ModelPreferencesStore.shared.isHidden($0.id) }
        let custom = ImageProviderStore.shared.syntheticModels.filter { !ModelPreferencesStore.shared.isHidden($0.id) }
        let local = LocalAIManager.shared.imageSyntheticModels.filter { !ModelPreferencesStore.shared.isHidden($0.id) }
        return Self.deduplicated(aqua + custom + local)
    }

    /// `chatModels` minus BYOK and local models — Model Compare has its own
    /// independent networking path that always calls Aqua directly (it isn't
    /// wired into per-provider routing), so it must only ever offer models
    /// Aqua itself can actually serve.
    var aquaOnlyChatModels: [APIModel] {
        chatModels.filter {
            CustomProviderStore.shared.config(owning: $0.id) == nil && !LocalAIManager.shared.owns($0.id)
        }
    }

    // MARK: - Code workspace (agentic coding panel)

    /// Files the model has created in the current conversation, derived by
    /// re-parsing the assistant messages (see `WorkspaceParser`).
    var workspaceFiles: [WorkspaceFile] = []
    /// Whether the right-side workspace panel is showing.
    var isWorkspaceOpen = false
    /// Path of the file currently shown in the workspace editor.
    var selectedWorkspacePath: String?
    /// Set when the user closes the panel mid-generation, so streaming
    /// updates stop re-opening it against their wishes.
    private var workspaceDismissedDuringGeneration = false
    /// The last file the stream auto-focused, so auto-follow only fires when
    /// the model moves to a *new* file — a user's manual tab click sticks.
    private var lastAutoFollowedPath: String?
    /// Runtime errors posted by the preview web view, waiting to ride along
    /// with the next request so the agent can fix its own website bugs.
    private(set) var pendingPreviewErrors: [String] = []
    /// Hard cap on agent-loop rounds per user message — prevents a runaway
    /// tool loop from re-posting the conversation forever. Eaon Claw gets a
    /// much larger budget: real on-device tasks ("sort my Downloads,"
    /// "research this and open the top three results") and real coding
    /// ("build a snake game," where each write→run→fix cycle is several
    /// steps) legitimately take many steps, where a plain chat turn rarely
    /// needs more than a handful. All are still bounded — the user can also
    /// stop generation at any time.
    private var maxAgentSteps: Int { (currentMode == .claw || currentMode == .agent) ? 40 : 16 }

    // MARK: - Run confirmation (agent code execution is unsandboxed — see WorkspaceRunner)

    private static let approvedRunConversationsKey = "approved_run_conversations"
    private var runConfirmationContinuation: CheckedContinuation<Bool, Never>?

    private var approvedRunConversationIds: Set<UUID> {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.approvedRunConversationsKey),
                  let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) else { return [] }
            return ids
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.approvedRunConversationsKey)
        }
    }

    /// Suspends the agent loop until the user allows or denies running
    /// generated code in the current conversation — asked once per
    /// conversation (persisted), never once per run. A conversation with
    /// no id yet (nothing saved) always asks, since there's nothing to
    /// remember approval against.
    private func confirmRunIfNeeded(path: String) async -> Bool {
        if AlwaysAllowStore.shared.isEnabled { return true }
        if let id = currentConversationId, approvedRunConversationIds.contains(id) { return true }

        pendingRunConfirmation = path
        let approved = await withCheckedContinuation { continuation in
            runConfirmationContinuation = continuation
        }
        pendingRunConfirmation = nil

        if approved, let id = currentConversationId {
            var ids = approvedRunConversationIds
            ids.insert(id)
            approvedRunConversationIds = ids
        }
        return approved
    }

    /// Called by the confirmation dialog's Allow/Don't Run buttons.
    func respondToRunConfirmation(allow: Bool) {
        runConfirmationContinuation?.resume(returning: allow)
        runConfirmationContinuation = nil
    }

    // MARK: - MCP call confirmation (unsandboxed, real external effects)

    private var mcpCallConfirmationContinuation: CheckedContinuation<Bool, Never>?

    /// Unlike `confirmRunIfNeeded`, this asks every single time rather than
    /// once per conversation — an MCP tool call has real, non-sandboxed
    /// external consequences on a real account (an issue, a pushed commit,
    /// a sent email, a charge) that a per-conversation "allow for this
    /// chat" would too easily rubber-stamp. `AlwaysAllowStore` bypasses this
    /// entirely when the user has turned it on; this per-call asking is
    /// only the behavior when that's off.
    private func confirmMCPCallIfNeeded(server: MCPServerDefinition, tool: String, argumentsJSON: String) async -> Bool {
        if AlwaysAllowStore.shared.isEnabled { return true }
        pendingMCPCallConfirmation = PendingMCPCall(serverDisplayName: server.displayName, tool: tool, argumentsJSON: argumentsJSON)
        let approved = await withCheckedContinuation { continuation in
            mcpCallConfirmationContinuation = continuation
        }
        pendingMCPCallConfirmation = nil
        return approved
    }

    /// Called by the confirmation dialog's Allow/Don't Allow buttons.
    func respondToMCPCallConfirmation(allow: Bool) {
        mcpCallConfirmationContinuation?.resume(returning: allow)
        mcpCallConfirmationContinuation = nil
    }

    // MARK: - Desktop control confirmation (real effects on this Mac)

    private static let approvedDesktopConversationsKey = "approved_desktop_conversations"
    private var desktopCallConfirmationContinuation: CheckedContinuation<DesktopConfirmDecision, Never>?

    private var approvedDesktopConversationIds: Set<UUID> {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.approvedDesktopConversationsKey),
                  let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) else { return [] }
            return ids
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.approvedDesktopConversationsKey)
        }
    }

    /// Read-only tools (`list_directory`) run without asking. Everything
    /// else asks, unless the user already granted this conversation blanket
    /// approval via "Allow for This Chat" (persisted per-conversation, like
    /// the coding agent's run approval). A brand-new unsaved chat has no id
    /// to remember against, so it always asks.
    private func confirmDesktopCallIfNeeded(tool: DesktopTool, arguments: [String: Any]) async -> Bool {
        if tool.isReadOnly { return true }
        // The coding Agent's Sandboxed/Auto toggle (Shift+Tab). In Auto mode
        // the user has explicitly opted out of per-command confirmation — the
        // whole point of the toggle — so commands run without asking. In
        // Sandboxed mode (the default) it falls through to the normal ask.
        // Never applies in Eaon Claw, which always uses its own confirm flow.
        if currentMode == .agent, agentAutoRun { return true }
        if let id = currentConversationId, approvedDesktopConversationIds.contains(id) { return true }

        pendingDesktopCallConfirmation = PendingDesktopCall(
            summary: tool.confirmationSummary(arguments: arguments),
            detail: tool.confirmationDetail(arguments: arguments)
        )
        let decision = await withCheckedContinuation { continuation in
            desktopCallConfirmationContinuation = continuation
        }
        pendingDesktopCallConfirmation = nil

        switch decision {
        case .deny:
            return false
        case .allowOnce:
            return true
        case .allowAll:
            if let id = currentConversationId {
                var ids = approvedDesktopConversationIds
                ids.insert(id)
                approvedDesktopConversationIds = ids
            }
            return true
        }
    }

    /// Called by the desktop confirmation dialog's three buttons.
    func respondToDesktopCallConfirmation(_ decision: DesktopConfirmDecision) {
        desktopCallConfirmationContinuation?.resume(returning: decision)
        desktopCallConfirmationContinuation = nil
    }

    // MARK: - Agent Sandboxed/Auto toggle (Shift+Tab)

    /// Shift+Tab (or a click on the permission pill) in the coding Agent.
    /// Leaving Auto → Sandboxed is always immediate — stepping toward the
    /// safer state needs no ceremony. Entering Sandboxed → Auto is gated:
    /// it pops the are-you-sure sheet rather than switching straight away,
    /// since Auto means the agent runs commands and edits files on the real
    /// disk without asking. No-op outside Agent mode.
    func requestAgentPermissionToggle() {
        guard currentMode == .agent else { return }
        if agentAutoRun {
            agentAutoRun = false
        } else {
            isAskingToEnterAutoMode = true
        }
    }

    /// The are-you-sure sheet's confirm button.
    func confirmEnterAutoMode() {
        isAskingToEnterAutoMode = false
        agentAutoRun = true
    }

    /// The are-you-sure sheet's cancel button (and its backdrop tap).
    func cancelEnterAutoMode() {
        isAskingToEnterAutoMode = false
    }

    func recordPreviewRuntimeError(_ text: String) {
        let trimmed = String(text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pendingPreviewErrors.count < 5, !pendingPreviewErrors.contains(trimmed) else { return }
        pendingPreviewErrors.append(trimmed)
        WorkspaceRunner.shared.note("preview error: \(trimmed)\n", kind: .stderr)
    }

    private let apiService = AquaAPIService()
    private static let selectedModelKey = "selected_model_id"
    private static let customInstructionsKey = "custom_instructions"
    private static let currentModeKey = "eaon_current_mode"
    private var typewriter: TypewriterStreamController?
    private var generationTask: Task<Void, Never>?

    /// User-authored, opt-in system instruction sent with every request —
    /// global, not per-conversation, matching how every other chat app's
    /// "custom instructions" works. Empty (the default) means no system
    /// message is sent at all, same as before this existed. This is the
    /// user explicitly choosing to steer the model, in full view in
    /// Settings — a deliberately different shape from the old hardcoded,
    /// invisible coding-agent prompt this app used to always send.
    var customInstructions: String = "" {
        didSet { UserDefaults.standard.set(customInstructions, forKey: Self.customInstructionsKey) }
    }

    init() {
        // Before anything reads a default: pull data stranded in an old
        // process-name/bundle-id domain (see LegacyDefaultsMigrator).
        LegacyDefaultsMigrator.migrateIfNeeded()
        // Carries a key saved under the old "aquadevs-api-key" account name
        // forward — see APIKeyStore's own doc comment.
        APIKeyStore.migrateLegacyAccountNameIfNeeded()
        if let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey) {
            selectedModel = saved
        }
        if let savedMode = UserDefaults.standard.string(forKey: Self.currentModeKey),
           let mode = EaonMode(rawValue: savedMode) {
            currentMode = mode
        }
        customInstructions = UserDefaults.standard.string(forKey: Self.customInstructionsKey) ?? ""
        loadConversations()
        loadProjects()
        refreshContextLimit()

        // No point calling an API that's guaranteed to reject an absent key —
        // onboarding triggers the first real fetch once a key is saved.
        if APIKeyStore.hasAPIKey {
            Task {
                await fetchModels()
            }
        }
    }

    // MARK: - Conversation persistence

    func loadConversations() {
        // Migrate a legacy single-chat store into a conversation, if present.
        if UserDefaults.standard.data(forKey: Self.conversationsKey) == nil,
           let legacy = UserDefaults.standard.data(forKey: "chat_messages"),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: legacy),
           !decoded.isEmpty {
            let migrated = Conversation(
                title: Self.deriveTitle(from: decoded),
                messages: decoded,
                createdAt: decoded.first?.timestamp ?? Date(),
                updatedAt: decoded.last?.timestamp ?? Date()
            )
            conversations = [migrated]
            persistConversations()
            UserDefaults.standard.removeObject(forKey: "chat_messages")
        } else if let data = UserDefaults.standard.data(forKey: Self.conversationsKey),
                  let decoded = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = decoded
        }
        // Always launch into a fresh, unsaved chat (ChatGPT-style home screen).
        messages = []
        currentConversationId = nil
    }

    private func persistConversations() {
        if let encoded = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(encoded, forKey: Self.conversationsKey)
        }
    }

    // MARK: - Project persistence

    func loadProjects() {
        if let data = UserDefaults.standard.data(forKey: Self.projectsKey),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
    }

    private func persistProjects() {
        if let encoded = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(encoded, forKey: Self.projectsKey)
        }
    }

    // MARK: - Export / import / delete-all

    /// A single conversation as portable JSON — `Conversation` is already
    /// `Codable`, so this is its own export format, and re-importing it
    /// (or a full `exportAllConversationsJSON` file) just decodes the same
    /// shape back. Static: it only ever needs the conversation passed in,
    /// so `ShareChatSheet` can call it without a `ChatViewModel` reference.
    static func exportConversationJSON(_ conversation: Conversation) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(conversation)
    }

    func exportAllConversationsJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(conversations)
    }

    /// A plain-text Markdown transcript — for reading or pasting
    /// elsewhere, not for re-importing (JSON is the round-trippable format).
    static func exportConversationMarkdown(_ conversation: Conversation) -> String {
        var lines = ["# \(conversation.title)", ""]
        for message in conversation.messages where !message.content.isEmpty {
            lines.append(message.isUser ? "**You**" : "**Assistant**")
            lines.append(message.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Merges an exported conversations JSON file back in. Existing chats
    /// (matched by id) are left untouched, so importing the same export
    /// twice — or importing onto the same Mac it came from — is harmless
    /// rather than duplicating everything. Accepts either a single
    /// exported conversation or a full array, matching whichever export
    /// path produced the file.
    @discardableResult
    func importConversations(from data: Data) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported: [Conversation]
        if let array = try? decoder.decode([Conversation].self, from: data) {
            imported = array
        } else if let single = try? decoder.decode(Conversation.self, from: data) {
            imported = [single]
        } else {
            return 0
        }
        let existingIds = Set(conversations.map(\.id))
        let newOnes = imported.filter { !existingIds.contains($0.id) }
        guard !newOnes.isEmpty else { return 0 }
        conversations.append(contentsOf: newOnes)
        persistConversations()
        return newOnes.count
    }

    /// Erases every chat and project on this Mac — the real action behind
    /// Privacy's "Delete all my data", which used to be read-only
    /// disclosure with nothing to actually act on.
    func deleteAllData() {
        conversations = []
        projects = []
        messages = []
        currentConversationId = nil
        persistConversations()
        persistProjects()
    }

    // MARK: - Project actions

    @discardableResult
    func createProject(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: trimmed.isEmpty ? "Untitled project" : trimmed)
        projects.append(project)
        persistProjects()
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = trimmed
        persistProjects()
    }

    /// Deletes the folder itself; the chats that were in it are kept, just
    /// un-grouped, rather than silently destroying someone's conversations.
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for index in conversations.indices where conversations[index].projectId == id {
            conversations[index].projectId = nil
        }
        persistConversations()
        persistProjects()
    }

    /// Writes the live `messages` back into the active conversation (creating it
    /// on first message) and persists the full list.
    func saveMessages() {
        guard !messages.isEmpty else {
            persistConversations()
            return
        }

        if let id = currentConversationId,
           let index = conversations.firstIndex(where: { $0.id == id }) {
            // Only a REAL change bumps `updatedAt` — `selectConversation`
            // calls `saveMessages()` unconditionally to flush the chat
            // being switched AWAY from, and with nothing actually
            // different there this used to still stamp "now" on it,
            // reordering the sidebar's most-recent-first list on every
            // click even though the user never typed anything.
            if conversations[index].messages != messages {
                conversations[index].messages = messages
                conversations[index].updatedAt = Date()
                if conversations[index].title == Conversation.placeholderTitle() {
                    conversations[index].title = Self.deriveTitle(from: messages)
                }
            }
        } else {
            let conversation = Conversation(
                title: Self.deriveTitle(from: messages),
                messages: messages,
                projectId: pendingProjectId
            )
            currentConversationId = conversation.id
            conversations.append(conversation)
        }
        persistConversations()
    }

    private static func deriveTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.isUser && !$0.content.isEmpty })?.content
                ?? messages.first?.content, !first.isEmpty else {
            return Conversation.placeholderTitle()
        }
        let flattened = first
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = flattened.count > 42 ? String(flattened.prefix(42)) + "…" : flattened
        return clipped.isEmpty ? Conversation.placeholderTitle() : clipped
    }

    // MARK: - Code workspace actions

    func openWorkspace(selecting path: String? = nil) {
        if let path { selectedWorkspacePath = path }
        if selectedWorkspacePath == nil { selectedWorkspacePath = workspaceFiles.first?.path }
        withAnimation(.easeOut(duration: 0.25)) { isWorkspaceOpen = true }
    }

    func closeWorkspace() {
        if isGenerating { workspaceDismissedDuringGeneration = true }
        withAnimation(.easeOut(duration: 0.2)) { isWorkspaceOpen = false }
    }

    private func resetWorkspace() {
        workspaceFiles = []
        isWorkspaceOpen = false
        selectedWorkspacePath = nil
        lastAutoFollowedPath = nil
    }

    /// Re-derives the workspace from the current messages. While streaming it
    /// also auto-opens the panel on the first file and follows the file the
    /// model is currently writing (Cursor-style).
    private func refreshWorkspace(streaming: Bool) {
        let parsed = WorkspaceParser.files(fromMessages: messages)
        if parsed != workspaceFiles { workspaceFiles = parsed }

        if streaming {
            if let active = parsed.last(where: { !$0.isComplete }) ?? parsed.last,
               active.path != lastAutoFollowedPath {
                lastAutoFollowedPath = active.path
                selectedWorkspacePath = active.path
            }
            if !parsed.isEmpty, !isWorkspaceOpen, !workspaceDismissedDuringGeneration {
                openWorkspace()
            }
        } else {
            if let selected = selectedWorkspacePath, !parsed.contains(where: { $0.path == selected }) {
                selectedWorkspacePath = parsed.first?.path
            }
            if selectedWorkspacePath == nil { selectedWorkspacePath = parsed.first?.path }
            if parsed.isEmpty, isWorkspaceOpen {
                withAnimation(.easeOut(duration: 0.2)) { isWorkspaceOpen = false }
            }
        }
    }

    // MARK: - Conversation actions

    /// Pass `projectId` to start a chat that will be filed into that project
    /// folder as soon as its first message is saved.
    func startNewChat(inProject projectId: UUID? = nil) {
        saveMessages()
        messages = []
        inputText = ""
        pendingAttachments = []
        composerNotice = nil
        isGenerating = false
        currentConversationId = nil
        pendingProjectId = projectId
        resetWorkspace()
    }

    func selectConversation(_ id: UUID) {
        guard id != currentConversationId else { return }
        saveMessages()
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        messages = conversation.messages
        currentConversationId = id
        inputText = ""
        pendingAttachments = []
        composerNotice = nil
        markRead(id)
        // Rebuild this conversation's workspace; the panel stays open only
        // if it was already open *and* the new chat actually has files.
        selectedWorkspacePath = nil
        lastAutoFollowedPath = nil
        refreshWorkspace(streaming: false)
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentConversationId == id {
            messages = []
            currentConversationId = nil
            resetWorkspace()
        }
        persistConversations()
    }

    /// Deletes only conversations not filed into a project — what the flat
    /// "Chats" list's own "Delete All" actually represents now that project
    /// chats live inside their folder instead of that list.
    func deleteAllUnfiledConversations() {
        if let current = currentConversationId,
           conversations.first(where: { $0.id == current })?.projectId == nil {
            messages = []
            currentConversationId = nil
            resetWorkspace()
        }
        conversations.removeAll { $0.projectId == nil }
        persistConversations()
    }

    func renameConversation(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = trimmed
        persistConversations()
    }

    private func markRead(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].hasUnread else { return }
        conversations[index].hasUnread = false
        persistConversations()
    }

    func fetchModels() async {
        isLoadingModels = true
        modelsLoadError = nil

        do {
            availableModels = Self.deduplicated(try await apiService.fetchModels())
            reconcileSelectedModel()
        } catch {
            availableModels = []
            modelsLoadError = error.localizedDescription
            print("Failed to fetch models: \(error)")
        }

        aquaImageModels = await AquaImageModels.fetchAvailable()

        // Refresh what's runnable locally alongside the remote catalog.
        await LocalAIManager.shared.refreshOllamaModels()
        reconcileSelectedModel()

        isLoadingModels = false
    }

    /// Keeps exactly one entry per model id, preferring whichever copy has
    /// a real display name, preserving first-seen order. Applied both to
    /// the raw Aqua fetch (the live catalog has returned the same id twice)
    /// and — the case that actually bites in practice — to the merged
    /// all-sources list in `allChatCapableModels`, where a BYOK gateway and
    /// Aqua's catalog can each serve the same id. SwiftUI's `ForEach`
    /// requires unique ids; duplicates don't render twice so much as
    /// corrupt the LazyVStack's layout (blank gaps, rows vanishing
    /// mid-scroll).
    private static func deduplicated(_ models: [APIModel]) -> [APIModel] {
        var byId: [String: APIModel] = [:]
        var order: [String] = []
        for model in models {
            if let existing = byId[model.id] {
                let existingHasName = !(existing.name?.isEmpty ?? true)
                let newHasName = !(model.name?.isEmpty ?? true)
                if !existingHasName, newHasName {
                    byId[model.id] = model
                }
            } else {
                byId[model.id] = model
                order.append(model.id)
            }
        }
        return order.compactMap { byId[$0] }
    }

    func selectModel(_ modelId: String) {
        selectedModel = modelId
        UserDefaults.standard.set(modelId, forKey: Self.selectedModelKey)
        warmIfLocalOllama(modelId)
        refreshContextLimit()
    }

    /// Switches mode from the sidebar. An image model can still be selected
    /// from the regular model picker regardless of mode — snapping back to a
    /// chat model here means switching modes never strands the surface
    /// unable to send.
    func enterMode(_ mode: EaonMode) {
        currentMode = mode
        let isImage = imageModels.contains { $0.id == selectedModel }
        if isImage, let first = chatModels.first {
            selectModel(first.id)
        }
    }

    /// The active model's context limit — nil while unknown (an
    /// unrecognized cloud model, or a local one that hasn't reported yet),
    /// in which case the UI simply shows no indicator rather than a guess.
    /// See `ContextWindowEstimator` for exactly how this is derived.
    var contextLimitTokens: Int?

    /// Rough token count for everything in the current conversation, using
    /// the same ~4 chars/token approximation `StatisticsTracker` already
    /// uses elsewhere in the app — kept consistent rather than inventing a
    /// second ratio.
    var estimatedUsedTokens: Int {
        StatisticsTracker.approxTokens(characters: messages.reduce(0) { $0 + $1.content.count })
    }

    func refreshContextLimit() {
        let modelId = selectedModel
        guard !modelId.isEmpty else {
            contextLimitTokens = nil
            return
        }
        Task {
            var liveLength: Int?
            if let record = LocalAIManager.shared.record(withId: modelId), record.backend == .ollama {
                liveLength = await LocalAIManager.shared.ollamaModelStatus(record.requestModelId)?.contextLength
            }
            let limit = await ContextWindowEstimator.contextLimit(modelId: modelId, liveOllamaContextLength: liveLength)
            // The model may have changed again while this was in flight.
            guard modelId == selectedModel else { return }
            contextLimitTokens = limit
        }
    }

    /// Starts loading a local Ollama model into memory the moment it's
    /// picked, rather than eating that load time on the first message sent
    /// to it. Fire-and-forget: `primeOllamaModel` already degrades silently
    /// on any failure, and nothing here blocks the picker UI.
    private func warmIfLocalOllama(_ modelId: String) {
        guard let record = LocalAIManager.shared.record(withId: modelId), record.backend == .ollama else { return }
        Task {
            await LocalAIManager.shared.primeOllamaModel(
                record.requestModelId,
                keepAlive: LocalAIManager.shared.ollamaKeepAliveDuration.rawValue
            )
        }
    }

    func hideModel(_ modelId: String) {
        ModelPreferencesStore.shared.hideModel(modelId)
        reconcileSelectedModel()
    }

    func restoreModel(_ modelId: String) {
        ModelPreferencesStore.shared.restoreModel(modelId)
        reconcileSelectedModel()
    }

    func toggleProvider(_ key: ModelProviderKey) {
        let isDisabled = ModelPreferencesStore.shared.isProviderDisabled(key)
        ModelPreferencesStore.shared.setProviderDisabled(key, disabled: !isDisabled)
        reconcileSelectedModel()
    }

    func saveCustomProvider(_ config: CustomProviderConfig, apiKey: String) throws {
        try CustomProviderStore.shared.save(config, apiKey: apiKey)
        reconcileSelectedModel()
    }

    func removeCustomProvider(_ id: UUID) {
        CustomProviderStore.shared.remove(id)
        reconcileSelectedModel()
    }

    func setModelNickname(_ nickname: String?, for modelId: String) {
        ModelPreferencesStore.shared.setNickname(nickname, for: modelId)
    }

    private func reconcileSelectedModel() {
        let selectable = chatModels
        guard !selectable.isEmpty else {
            selectedModel = ""
            return
        }

        if selectable.contains(where: { $0.id == selectedModel }) {
            return
        }

        selectedModel = selectable[0].id
        UserDefaults.standard.set(selectedModel, forKey: Self.selectedModelKey)
    }

    func addAttachment(from url: URL, kind: AttachmentKind) {
        do {
            let attachment = try AttachmentStore.importFile(from: url, kind: kind)
            pendingAttachments.append(attachment)
            composerNotice = nil
        } catch {
            composerNotice = "Could not add attachment: \(error.localizedDescription)"
        }
    }

    func pasteImageAttachment() {
        do {
            guard let attachment = try AttachmentStore.importImageFromPasteboard() else {
                composerNotice = "No image found on the clipboard."
                return
            }
            pendingAttachments.append(attachment)
            composerNotice = nil
        } catch {
            composerNotice = "Could not paste image: \(error.localizedDescription)"
        }
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Kicks off a cancellable generation. The composer calls this instead of
    /// awaiting `sendMessage` directly so the stop button can interrupt it.
    func startSend() {
        generationTask?.cancel()
        generationTask = Task { await sendMessage() }
    }

    func stopGeneration() {
        typewriter?.markStreamFinished()
        generationTask?.cancel()
        generationTask = nil
    }

    /// Image generation is one request/response — no agent loop, no
    /// streaming, no tool-calling, no system prompt, no conversation
    /// history sent upstream. Kept as its own path entirely separate from
    /// `sendMessage`'s agent loop rather than threading image-awareness
    /// through that much larger, more delicate pipeline.
    private func sendImageGenerationMessage(prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendSystemError("Describe the image you want before sending.")
            return
        }

        let modelId = selectedModel
        messages.append(ChatMessage(content: trimmed, isUser: true))
        StatisticsTracker.shared.recordUserPrompt(modelId: modelId)
        inputText = ""
        pendingAttachments = []
        composerNotice = nil
        saveMessages()

        isGenerating = true
        StatisticsTracker.shared.currentGeneratingModel = modelId
        defer {
            isGenerating = false
            StatisticsTracker.shared.currentGeneratingModel = ""
        }

        let loadingId = UUID()
        messages.append(ChatMessage(id: loadingId, content: "Generating image…", isUser: false, modelId: modelId))
        saveMessages()

        do {
            let result: GeneratedImageResult
            if let config = ImageProviderStore.shared.config(owning: modelId) {
                let key = ImageProviderStore.shared.apiKey(for: config.id)
                result = try await config.generate(model: modelId, prompt: trimmed, apiKey: key)
            } else if let record = LocalAIManager.shared.record(withId: modelId), record.isImageGeneration == true {
                result = try await OllamaImageFormat.generate(model: record.requestModelId, prompt: trimmed)
            } else {
                guard let aquaKey = APIKeyStore.loadAPIKey(), !aquaKey.isEmpty else {
                    markError(id: loadingId, text: "Add your Aqua API key in Settings → Aqua API to generate images.")
                    return
                }
                result = try await AquaImageModels.generate(model: modelId, prompt: trimmed, apiKey: aquaKey)
            }

            let attachment = try AttachmentStore.importImageData(result.data, fileName: result.suggestedFileName)
            guard let index = messages.firstIndex(where: { $0.id == loadingId }) else { return }
            messages[index].content = ""
            messages[index].attachments = [attachment]
            messages[index].isGeneratedImage = true
            saveMessages()
        } catch {
            markError(id: loadingId, text: error.localizedDescription)
        }
    }

    /// A `/skill-name` invocation for the message currently being sent —
    /// set fresh at the top of every `sendMessage()` call (including back
    /// to `nil` when there's no leading slash command), so a skill applies
    /// to the request it was invoked for and nothing after. Read by
    /// `systemPromptHistory`.
    private var activeSkillForTurn: Skill?

    /// Detects a leading `/skill-name` in the user's raw input. The name
    /// must be installed AND enabled (`SkillStore.skill(named:)` already
    /// restricts to enabled), otherwise this is just an ordinary message
    /// that happens to start with a slash. Returns the matched skill and
    /// the text with that leading token removed; if the skill consumed the
    /// entire message (nothing typed after it), a short generic fallback
    /// stands in as the text so the turn still has something to send.
    static func extractSkillInvocation(from text: String) -> (skill: Skill?, text: String) {
        guard text.hasPrefix("/") else { return (nil, text) }
        let withoutSlash = text.dropFirst()
        let name = withoutSlash.prefix { !$0.isWhitespace }
        guard !name.isEmpty, let skill = SkillStore.shared.skill(named: String(name)) else { return (nil, text) }
        let rest = withoutSlash.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (skill, rest.isEmpty ? "Use the \"\(skill.name)\" skill." : rest)
    }

    func sendMessage() async {
        let rawInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let (invokedSkill, text) = Self.extractSkillInvocation(from: rawInput)
        activeSkillForTurn = invokedSkill
        let attachments = pendingAttachments
        guard (!text.isEmpty || !attachments.isEmpty), !isGenerating else { return }

        // Image models never appear in `chatModels` at all — this has to be
        // checked before that guard, not inside it.
        if imageModels.contains(where: { $0.id == selectedModel }) {
            await sendImageGenerationMessage(prompt: text)
            return
        }

        guard !selectedModel.isEmpty, chatModels.contains(where: { $0.id == selectedModel }) else {
            // This fires for any reason the selection doesn't resolve —
            // still-loading, zero providers configured at all, or a stale
            // selection left over from a deleted/hidden model — so the
            // message must reflect which of those it actually is instead of
            // always blaming Aqua specifically (chatModels merges Aqua,
            // BYOK, and local models; most users hitting this have neither
            // an Aqua key nor any Aqua models loaded).
            if isLoadingModels {
                appendSystemError("Still loading models — wait a moment, then pick one from the menu.")
            } else if chatModels.isEmpty {
                appendSystemError("No models available yet. Add a provider or API key in Settings, or download a local model from Settings → Models.")
            } else {
                appendSystemError("No chat model selected. Pick one from the model menu above.")
            }
            return
        }

        // Routing precedence: BYOK config → local model (Ollama/llama.cpp/
        // MLX, no key at all) → Aqua.
        let customConfig = CustomProviderStore.shared.config(owning: selectedModel)
        let localRecord = customConfig == nil ? LocalAIManager.shared.record(withId: selectedModel) : nil

        let apiKey: String
        if let customConfig {
            guard let customKey = CustomProviderStore.shared.apiKey(for: customConfig.id), !customKey.isEmpty else {
                appendSystemError("No API key saved for \(customConfig.displayName). Add one in Settings → Custom Providers.")
                return
            }
            apiKey = customKey
        } else if localRecord != nil {
            // Local servers don't authenticate; they ignore the header.
            apiKey = "local-no-key"
        } else {
            guard let aquaKey = APIKeyStore.loadAPIKey(), !aquaKey.isEmpty else {
                appendSystemError("Add your Aqua API key in Settings → Aqua API to start chatting.")
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                return
            }
            apiKey = aquaKey
        }

        let userMsg = ChatMessage(content: text, isUser: true, attachments: attachments, invokedSkillName: invokedSkill?.name)
        messages.append(userMsg)
        StatisticsTracker.shared.recordUserPrompt(modelId: selectedModel)
        inputText = ""
        pendingAttachments = []
        composerNotice = nil

        // Self-correction for websites: runtime errors captured from the
        // live preview ride into this turn so the agent can fix them.
        if !pendingPreviewErrors.isEmpty {
            let note = "[Preview runtime errors — captured from the live preview of this workspace]\n"
                + pendingPreviewErrors.joined(separator: "\n")
            messages.append(ChatMessage(content: note, isUser: false, isToolResult: true))
            pendingPreviewErrors = []
        }
        saveMessages()

        isGenerating = true
        StatisticsTracker.shared.currentGeneratingModel = selectedModel
        workspaceDismissedDuringGeneration = false
        lastAutoFollowedPath = nil

        // The agent loop: stream a reply, execute any tools it requested,
        // feed the results back as a message, repeat until a reply requests
        // nothing. A plain chat answer is just the 1-step case.
        var identicalFailureStreak = 0
        var lastFailureSignature: String?

        let stepBudget = maxAgentSteps
        for step in 1...stepBudget {
            let outcome = await streamOneAgentStep(customConfig: customConfig, localRecord: localRecord, apiKey: apiKey)
            guard case .completed(let stepMsgId, let replyText) = outcome, !Task.isCancelled else { break }

            // A "successful" stream that produced literally nothing — no
            // error thrown, no tokens either — used to leave a permanently
            // blank bubble with zero explanation. Most often a local model
            // buckling under a large prompt (e.g. several connected
            // plugins' tool descriptions); surface it instead of going
            // silent.
            if replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markError(id: stepMsgId, text: "No response was generated. This can happen with a local model under a large prompt — try disconnecting a plugin you're not using right now, or try again.")
                break
            }

            guard let toolRun = await executeAgentTools(inReplyText: replyText) else { break }

            messages.append(ChatMessage(content: toolRun.results, isUser: false, isToolResult: true))
            saveMessages()

            // If the exact same run failure comes back three times, stop
            // burning tokens and leave it with the user.
            if let signature = toolRun.failureSignature {
                if signature == lastFailureSignature {
                    identicalFailureStreak += 1
                } else {
                    identicalFailureStreak = 1
                    lastFailureSignature = signature
                }
                if identicalFailureStreak >= 3 {
                    messages.append(ChatMessage(
                        content: "Stopped — the same error came back three times in a row. Tell the model what to try differently, or edit the file yourself in the workspace.",
                        isUser: false,
                        isError: true
                    ))
                    saveMessages()
                    break
                }
            } else {
                identicalFailureStreak = 0
                lastFailureSignature = nil
            }

            if Task.isCancelled { break }
            if step == stepBudget {
                WorkspaceRunner.shared.note("● Agent paused after \(stepBudget) rounds — send a message to continue.\n", kind: .status)
            }
        }

        self.typewriter = nil
        self.generationTask = nil
        activeTypingMessageId = nil
        isGenerating = false
        StatisticsTracker.shared.currentGeneratingModel = ""
        refreshWorkspace(streaming: false)

        triggerMemoryExtractionIfNeeded(customConfig: customConfig, localRecord: localRecord, apiKey: apiKey)
    }

    /// Fires a silent, best-effort background extraction after a turn
    /// finishes — never blocks or affects the visible chat either way. See
    /// `MemoryExtractor` for why this is a plain completion call rather
    /// than tool-calling.
    private func triggerMemoryExtractionIfNeeded(
        customConfig: CustomProviderConfig?,
        localRecord: LocalModelRecord?,
        apiKey: String
    ) {
        guard MemoryStore.shared.isEnabled, MemoryStore.shared.isAutoLearnEnabled else { return }
        // `!isError` too — a turn that ended on the 3-strikes stop message
        // used to feed that error text in as "what the assistant said,"
        // polluting extraction with mechanical noise.
        guard let lastUserIndex = messages.lastIndex(where: { $0.isUser }),
              case let lastUser = messages[lastUserIndex].content, !lastUser.isEmpty,
              let lastAssistant = messages.last(where: { !$0.isUser && $0.isToolResult != true && !$0.isError })?.content,
              !lastAssistant.isEmpty else { return }

        // This turn's plugin/tool results ride along ONLY with the user's
        // separate, off-by-default consent — plugin output routinely
        // carries other people's information and content the user never
        // typed. Capped like every other request-size guard in this app.
        var toolContext: String?
        if MemoryStore.shared.isPluginLearnEnabled {
            let turnToolResults = messages[messages.index(after: lastUserIndex)...]
                .filter { $0.isToolResult == true }
                .map(\.content)
                .joined(separator: "\n")
            if !turnToolResults.isEmpty {
                toolContext = String(turnToolResults.prefix(4000))
            }
        }

        let aquaApiKey = (customConfig == nil && localRecord == nil) ? apiKey : nil
        let modelId = selectedModel
        Task {
            await MemoryExtractor.run(
                userText: lastUser,
                assistantText: lastAssistant,
                toolContext: toolContext,
                customConfig: customConfig,
                localRecord: localRecord,
                aquaApiKey: aquaApiKey,
                modelId: modelId
            )
        }
    }

    // MARK: - Learn memories from a user-chosen file

    var isLearningFromFile = false

    /// The heavy-consent path for file-based memory: by the time this is
    /// called, the user has explicitly PICKED the file in an open panel
    /// AND confirmed a dialog spelling out exactly what will be sent where
    /// (see `MemorySettingsView`). Uses the same model routing as the
    /// backfill; reports through `memoryBackfillStatus`, which that page
    /// already displays.
    func learnFromFile(url: URL) {
        guard !isLearningFromFile, !isBackfillingMemory else { return }
        guard !selectedModel.isEmpty else {
            memoryBackfillStatus = "Pick a model in the chat first — learning uses whichever one is currently selected."
            return
        }

        let customConfig = CustomProviderStore.shared.config(owning: selectedModel)
        let localRecord = customConfig == nil ? LocalAIManager.shared.record(withId: selectedModel) : nil
        var aquaApiKey: String?
        if customConfig == nil, localRecord == nil {
            guard let key = APIKeyStore.loadAPIKey(), !key.isEmpty else {
                memoryBackfillStatus = "Add your Aqua API key first, or switch to a model that already has one."
                return
            }
            aquaApiKey = key
        }

        let accessed = url.startAccessingSecurityScopedResource()
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            memoryBackfillStatus = "Couldn't read \"\(url.lastPathComponent)\" as text."
            return
        }
        if accessed { url.stopAccessingSecurityScopedResource() }

        isLearningFromFile = true
        memoryBackfillStatus = "Reading \"\(url.lastPathComponent)\"…"
        let modelId = selectedModel
        let fileName = url.lastPathComponent
        Task {
            do {
                let added = try await MemoryExtractor.runOnFileText(
                    text, fileName: fileName,
                    customConfig: customConfig, localRecord: localRecord,
                    aquaApiKey: aquaApiKey, modelId: modelId
                )
                memoryBackfillStatus = added > 0
                    ? "Learned \(added) new thing\(added == 1 ? "" : "s") from \"\(fileName)\" — review below."
                    : "Nothing new worth remembering was found in \"\(fileName)\"."
            } catch {
                memoryBackfillStatus = "Couldn't learn from \"\(fileName)\": \(error.localizedDescription)"
            }
            isLearningFromFile = false
        }
    }

    /// Mines every saved conversation for durable facts, not just ones
    /// going forward — explicit, user-triggered from Settings → Memory,
    /// since unlike the silent per-turn extraction above this makes one
    /// real request per conversation and could mean a real number of API
    /// calls (time, and on a paid model, money) for someone with a long
    /// chat history. Uses whichever model is currently selected in the
    /// chat — the same routing precedence (BYOK → local → Aqua) as
    /// actually sending a message uses.
    func startMemoryBackfill() {
        guard !isBackfillingMemory else { return }
        guard !selectedModel.isEmpty else {
            memoryBackfillStatus = "Pick a model in the chat first — backfill uses whichever one is currently selected."
            return
        }

        let customConfig = CustomProviderStore.shared.config(owning: selectedModel)
        let localRecord = customConfig == nil ? LocalAIManager.shared.record(withId: selectedModel) : nil

        var aquaApiKey: String?
        if let customConfig {
            guard let key = CustomProviderStore.shared.apiKey(for: customConfig.id), !key.isEmpty else {
                memoryBackfillStatus = "No API key saved for \(customConfig.displayName) — add one in Settings first."
                return
            }
        } else if localRecord == nil {
            guard let key = APIKeyStore.loadAPIKey(), !key.isEmpty else {
                memoryBackfillStatus = "Add your Aqua API key first, or switch to a model that already has one."
                return
            }
            aquaApiKey = key
        }

        guard !conversations.isEmpty else {
            memoryBackfillStatus = "No saved chats yet to learn from."
            return
        }

        isBackfillingMemory = true
        memoryBackfillCancelRequested = false
        memoryBackfillStatus = "Starting…"
        let modelId = selectedModel
        let candidateConversations = conversations

        Task {
            let result = await MemoryExtractor.runBackfill(
                conversations: candidateConversations,
                customConfig: customConfig,
                localRecord: localRecord,
                aquaApiKey: aquaApiKey,
                modelId: modelId,
                onProgress: { [weak self] completed, total, newFacts in
                    self?.memoryBackfillStatus = "Reviewed \(completed) of \(total) chats — \(newFacts) new fact\(newFacts == 1 ? "" : "s") so far…"
                },
                isCancelled: { [weak self] in self?.memoryBackfillCancelRequested ?? true }
            )
            self.isBackfillingMemory = false
            self.memoryBackfillStatus = Self.backfillSummary(for: result)
        }
    }

    func cancelMemoryBackfill() {
        memoryBackfillCancelRequested = true
    }

    private static func backfillSummary(for result: MemoryExtractor.BackfillResult) -> String {
        let factsPart = "\(result.factsAdded) new fact\(result.factsAdded == 1 ? "" : "s")"
        if result.stoppedEarly && result.conversationsReviewed < result.conversationsTotal {
            return "Stopped after \(result.conversationsReviewed) of \(result.conversationsTotal) chats — learned \(factsPart)."
        }
        return "Done — reviewed \(result.conversationsReviewed) chat\(result.conversationsReviewed == 1 ? "" : "s"), learned \(factsPart)."
    }

    private enum AgentStepOutcome {
        case completed(id: UUID, text: String)
        case cancelled
        case failed
    }

    /// Merges connected MCP tools with the built-in web search tool (when
    /// enabled) into one native `tools` array — nil when both are absent,
    /// so a plain chat request stays untouched. Web search never needs an
    /// entry in `nameMap`: `ToolCallAccumulator.fencedBlocks` recognizes
    /// `WebSearchTool.nativeFunctionName` on its own, before it ever
    /// consults the map (see that function's doc comment).
    private static func mergedNativeTools(mode: EaonMode) -> NativeToolConfig? {
        let inClaw = mode == .claw && DesktopControlStore.shared.isEnabled
        let inCodingAgent = mode == .agent
        var tools: [[String: Any]] = []
        var nameMap: [String: (server: String, tool: String)] = [:]
        // Cloud plugins belong to Chat, not the device-driving modes — see
        // `systemPromptHistory` for why loading them alongside device tools
        // made a weaker model lose track of those tools entirely. The coding
        // Agent gets the same focused treatment: its own file/shell tools,
        // not a dozen unrelated cloud plugins competing for attention.
        if !inClaw, !inCodingAgent, let mcpConfig = MCPConnectionStore.shared.nativeToolConfig {
            tools += mcpConfig.tools
            nameMap = mcpConfig.nameMap
        }
        if WebSearchStore.shared.isEnabled {
            tools.append(WebSearchTool.nativeDefinition)
        }
        // Eaon Claw gets the full device catalog (files, apps, browser). The
        // coding Agent gets the focused coding subset (write/run/inspect) —
        // enough to build software on the real disk, without the
        // app/browser-driving tools that would dilute a smaller model's
        // focus. Chat gets neither.
        if inClaw {
            tools.append(contentsOf: DesktopControlTool.nativeDefinitions)
        } else if inCodingAgent {
            tools.append(contentsOf: DesktopControlTool.codingNativeDefinitions)
        }
        guard !tools.isEmpty else { return nil }
        return NativeToolConfig(tools: tools, nameMap: nameMap)
    }

    /// Streams one assistant reply (one loop step) into its own chat bubble,
    /// preserving the exact per-message lifecycle the single-shot path had.
    private func streamOneAgentStep(
        customConfig: CustomProviderConfig?,
        localRecord: LocalModelRecord? = nil,
        apiKey: String
    ) async -> AgentStepOutcome {
        let aiMsgId = UUID()
        let selected = chatModels.first { $0.id == selectedModel }
        messages.append(
            ChatMessage(
                id: aiMsgId,
                content: "",
                isUser: false,
                modelId: selectedModel,
                modelName: selected?.name,
                generationStartTime: Date()
            )
        )
        activeTypingMessageId = aiMsgId

        let typewriter = TypewriterStreamController { [weak self] displayed in
            self?.setAssistantMessageContent(id: aiMsgId, content: displayed)
        }
        self.typewriter = typewriter

        // Connected plugins + web search (if enabled) ride along as native
        // API tools (the calling mechanism hosted models are trained on) —
        // nil when neither is present, so plain chat requests are untouched.
        // Desktop tools are added only in Eaon Claw (see mergedNativeTools).
        let nativeTools = Self.mergedNativeTools(mode: currentMode)

        var outcome: AgentStepOutcome
        do {
            if let customConfig {
                try await streamCustomCompletion(config: customConfig, apiKey: apiKey, typewriter: typewriter, nativeTools: nativeTools)
            } else if let localRecord {
                try await streamLocalCompletion(record: localRecord, aiMsgId: aiMsgId, typewriter: typewriter, nativeTools: nativeTools)
            } else {
                try await streamCompletion(apiKey: apiKey, aiMessageId: aiMsgId, typewriter: typewriter, nativeTools: nativeTools)
            }
            typewriter.markStreamFinished()
            await typewriter.waitUntilCaughtUp()
            finalizeGeneration(id: aiMsgId)
            saveMessages()
            outcome = .completed(id: aiMsgId, text: messages.first(where: { $0.id == aiMsgId })?.content ?? "")
        } catch is CancellationError {
            typewriter.markStreamFinished()
            await typewriter.waitUntilCaughtUp()
            finalizeGeneration(id: aiMsgId)
            saveMessages()
            outcome = .cancelled
        } catch let error as URLError where error.code == .cancelled {
            typewriter.markStreamFinished()
            await typewriter.waitUntilCaughtUp()
            finalizeGeneration(id: aiMsgId)
            saveMessages()
            outcome = .cancelled
        } catch {
            typewriter.cancel()
            markError(id: aiMsgId, text: error.localizedDescription)
            outcome = .failed
        }

        self.typewriter = nil
        activeTypingMessageId = nil
        loadingStatusText = nil
        return outcome
    }

    private struct AgentToolRun {
        let results: String
        /// Non-nil only when a run failed — drives the repeat-error stop.
        let failureSignature: String?
    }

    /// Mirrors the `read` case's own 12,000-character cap just below —
    /// unlike file reads, MCP tool results (a repo search, a list of
    /// issues, an analytics query) had no cap at all until this was
    /// added. A large result feeding straight back into the next
    /// request's history is exactly the kind of oversized-body request a
    /// flaky gateway 502s on, and it silently compounds every further
    /// round the agent loop takes.
    private static func boundedToolResultText(_ text: String) -> String {
        guard text.count > 12_000 else { return text }
        return String(text.prefix(12_000)) + "\n…(truncated — ask a narrower question if you need what's past this point)"
    }

    /// An empty/whitespace-only body is a valid "no arguments" call — only
    /// text that's actually present and NOT valid JSON is an error.
    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// Source-code fence languages a model might use for a bare,
    /// unattributed code block — the plainest possible way a chat-tuned
    /// model "delivers" a file without ever calling a tool. Only consulted
    /// in Agent mode, where that's a silent no-op the user experiences as
    /// "it didn't write anything," not a harmless conversational aside.
    private static let bareCodeFenceLanguages: Set<String> = [
        "python", "py", "javascript", "js", "jsx", "typescript", "ts", "tsx",
        "swift", "ruby", "rb", "go", "golang", "rust", "rs", "java", "kotlin",
        "kt", "php", "sh", "bash", "zsh", "shell", "perl", "lua", "c", "cpp",
        "c++", "html", "css",
    ]

    /// True when the reply contains a *complete* fenced code block in a
    /// recognizable programming language with no `file=`/`path=`/`eaon:`
    /// attribute at all — code the model printed instead of writing with a
    /// real tool call. Deliberately requires a closed fence (a still-open
    /// trailing one is skipped) since this only runs on finished text.
    private static func containsBareCodeFence(_ text: String) -> Bool {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return false }
        var index = 1
        while index < parts.count - 1 {
            let body = parts[index]
            let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let info = WorkspaceParser.fenceInfo(from: firstLine)
            if info.path == nil, info.tool == nil, info.server == nil,
               let language = info.language, bareCodeFenceLanguages.contains(language) {
                return true
            }
            index += 2
        }
        return false
    }

    /// Executes the run/edit/read/ls tools a reply requested, against a
    /// working snapshot that replays the reply's own events in order — so
    /// each tool sees exactly the file state the model had produced by that
    /// point. Returns nil when the reply requested nothing (loop ends).
    private func executeAgentTools(inReplyText replyText: String) async -> AgentToolRun? {
        // assumeFinal: this text is DONE streaming, so a trailing block
        // with no closing fence is a model that stopped mid-fence, not a
        // stream still writing — execute it rather than dropping it.
        // The same think-stripped view of the reply the parser itself works
        // on — the fence-presence checks below must look at the same text,
        // or a fence QUOTED inside the model's reasoning would trigger the
        // "couldn't be parsed" error for a reply that made no call at all.
        let visibleReply = WorkspaceParser.strippedOfThinking(replyText)
        let events = WorkspaceParser.events(from: replyText, assumeFinal: true)
        let hasActions = events.contains { event in
            // In Chat's sandboxed code workspace, a `.write` is inert on its
            // own (no run/read/etc. alongside it) and shouldn't trip the
            // "nothing happened" error below. In Agent mode there's no
            // sandbox to fall back on — a bare file fence is a real, if
            // wrongly-formatted, attempt to create a file (see the `.write`
            // case below, which either saves it for real or explains why
            // not), so it counts as an action here too.
            if case .write = event { return currentMode == .agent }
            return true
        }
        guard hasActions else {
            // A reply that is ONLY reasoning — a <think> span (closed or
            // trailing off) with no visible text and no tool call after it.
            // Observed live (Nemotron 3 Ultra, 2026-07-14): the model plans
            // the next action INSIDE its thinking ("Now I'll create the
            // HTML file…"), closes </think>, and stops. Ending the loop
            // there reads as the agent silently giving up, and the user has
            // to hand-type "continue" after every step. Bounce it back
            // instead — the agentic contract is act or conclude, never just
            // think — with a signature so three thinking-only turns in a
            // row stop cleanly. Agent/Claw only: plain Chat has no loop to
            // keep alive.
            if currentMode == .agent || currentMode == .claw {
                // Complete think spans are already gone from visibleReply;
                // any "<think" still present is an unclosed span trailing
                // to the end — ignore it for the emptiness check too.
                var checkText = visibleReply
                if let unclosed = checkText.range(of: "<think", options: .caseInsensitive) {
                    checkText = String(checkText[..<unclosed.lowerBound])
                }
                if checkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let example = currentMode == .agent
                        ? "```eaon:computer tool=\"write_file\"\n{\"path\": \"~/<project>/index.html\", \"content\": \"<!doctype html>\\n…the complete file…\"}\n```"
                        : "```eaon:computer tool=\"list_directory\"\n{\"path\": \"~/Downloads\"}\n```"
                    return AgentToolRun(
                        results: "[Tool results — automated, not written by the user]\n\n### tool call\nERROR: your reply was only internal thinking — it ended with no visible text and no tool call, so NOTHING happened. Do not think again; ACT. Emit the next tool call now, as a fence at the start of its own line:\n\(example)\nAfter your reasoning you must always either call a tool or, when the task is finished, give the user a short plain-language answer.",
                        failureSignature: "thinking-only-turn"
                    )
                }
            }
            // Agent mode specifically: the model printed source as a plain
            // code block with no attribute of any kind (not even `file=`) —
            // the single most natural thing a chat-tuned model does when
            // asked to "build" something, and the one case with no `.write`
            // event at all to hook into. Nothing was ever going to land on
            // disk from this, so say so before the loop just quietly ends.
            if currentMode == .agent, Self.containsBareCodeFence(visibleReply) {
                return AgentToolRun(
                    results: "[Tool results — automated, not written by the user]\n\n### tool call\nERROR: no tool was called, so nothing was created — a code block in the chat doesn't save to disk. If that was meant to be a file, write it for real:\n```eaon:computer tool=\"write_file\"\n{\"path\": \"~/project/main.py\", \"content\": \"print('hi')\\n\"}\n```\nAvailable tools: \(DesktopTool.codingTools.map(\.rawValue).joined(separator: ", ")).",
                    failureSignature: "agent-code-no-tool-call"
                )
            }
            // The reply LOOKS like it attempted a tool call (an eaon:/
            // aqua: fence is present) but nothing parseable came out.
            // Returning nil here would end the loop with no reply and no
            // error — the model must instead be told the call didn't
            // happen, so it can re-emit it correctly. The re-emit example
            // MUST match the mode's actual tools: telling a coding-Agent or
            // Claw model to use the `eaon:mcp server="<server id>"` form
            // (the old hardcoded text) made it copy that literal placeholder
            // and spiral into "<server id> isn't a connected service." A
            // real failureSignature is set now too, so an identical parse
            // failure three times running stops the loop instead of burning
            // steps until the gateway 502s.
            if visibleReply.contains("```eaon:") || visibleReply.contains("```aqua:") {
                let usesComputerTools = currentMode == .agent || currentMode == .claw
                let example = usesComputerTools
                    ? "```eaon:computer tool=\"write_file\"\n{\"path\": \"~/project/main.py\", \"content\": \"print('hi')\\n\"}\n```"
                    : "```eaon:mcp server=\"<server id>\" tool=\"<tool name>\"\n{\"arg\": \"value\"}\n```"
                // On its own line after the example's closing fence — glued
                // to it, this hint itself modeled the exact
                // text-on-the-fence-line mistake it was trying to correct.
                let toolsHint = usesComputerTools
                    ? "\nYour tools are called with `tool=\"<name>\"` on the fence line and a JSON body. Available tools: \(DesktopTool.codingTools.map(\.rawValue).joined(separator: ", ")). The opening ```eaon:computer must START its own line (nothing else before it on that line), the closing ``` goes on its own line, and every newline inside a JSON string is written as \\n."
                    : ""
                return AgentToolRun(
                    results: "[Tool results — automated, not written by the user]\n\n### tool call\nERROR: a tool block in your reply couldn't be parsed, so nothing was executed. Re-emit it EXACTLY like this, with the closing ``` fence on its own line:\n\(example)\(toolsHint)",
                    failureSignature: "unparseable-tool-block"
                )
            }
            return nil
        }

        // Snapshot of the workspace before this reply (the reply itself is
        // the last message right now).
        var ordered: [String] = []
        var byPath: [String: WorkspaceFile] = [:]
        for file in WorkspaceParser.files(fromMessages: Array(messages.dropLast())) {
            ordered.append(file.path)
            byPath[file.path] = file
        }

        var sections: [String] = []
        var failureSignature: String?

        for event in events {
            if Task.isCancelled { break }
            switch event {
            case .write(let file):
                if byPath[file.path] == nil { ordered.append(file.path) }
                byPath[file.path] = file

                // Agent mode has no ephemeral sandbox to fall back on — a
                // plain `file="..."` fence or the `eaon:write` shorthand is
                // a real attempt to create a file, just via the wrong fence
                // (the app's own workspace panel re-derives from every
                // assistant message regardless of mode, so it would show
                // this file as if it existed — a UI promise the disk never
                // kept unless it lands here). `sanitizePath` always strips a
                // leading "/" from a truly absolute path (so one can never
                // be told apart from a bare relative one), but it leaves a
                // leading "~/" untouched — an unambiguous signal the model
                // meant a real, home-anchored location. Only that case is
                // safe to auto-promote to a real write; anything else is
                // told what's missing instead of guessing a location.
                guard currentMode == .agent else { continue }
                guard file.path.hasPrefix("~/") else {
                    sections.append("### \(file.fileName)\nERROR: this only rendered in the chat's preview — nothing was saved to disk, since the path wasn't anchored to a real location. Save it for real with an absolute path under your project folder:\n```eaon:computer tool=\"write_file\"\n{\"path\": \"~/<project-folder>/\(file.fileName)\", \"content\": \"<same file content, every line break as \\n>\"}\n```")
                    failureSignature = "agent-plain-write-\(file.path)"
                    WorkspaceRunner.shared.note("✗ \(file.path) — not saved (no absolute path)\n", kind: .stderr)
                    continue
                }
                guard await confirmDesktopCallIfNeeded(tool: .writeFile, arguments: ["path": file.path, "content": file.content]) else {
                    sections.append("### \(file.path)\nSkipped — you didn't allow this action.")
                    WorkspaceRunner.shared.note("✗ computer: Write file — not allowed\n", kind: .stderr)
                    continue
                }
                agentActivityText = "Running \(DesktopTool.writeFile.displayName)…"
                defer { agentActivityText = nil }
                let writeResult = await DesktopControlService.execute(tool: .writeFile, arguments: ["path": file.path, "content": file.content])
                if writeResult.isError {
                    sections.append("### \(file.path)\nERROR:\n\(Self.boundedToolResultText(writeResult.text))")
                    WorkspaceRunner.shared.note("✗ computer: Write file\n", kind: .stderr)
                } else {
                    sections.append("### \(file.path)\nOK:\n\(Self.boundedToolResultText(writeResult.text))")
                    WorkspaceRunner.shared.note("✓ computer: Write file (\(file.path))\n", kind: .status)
                }

            case .edit(let path, let payload):
                guard let payload else {
                    sections.append("### edit \(path)\nERROR: malformed edit block — the body must contain <<<<<<< SEARCH, =======, and >>>>>>> REPLACE lines.")
                    WorkspaceRunner.shared.note("✗ edit \(path) — malformed block\n", kind: .stderr)
                    continue
                }
                guard var file = byPath[path] else {
                    sections.append("### edit \(path)\nERROR: no file named \(path) exists. Files: \(ordered.joined(separator: ", "))")
                    WorkspaceRunner.shared.note("✗ edit \(path) — no such file\n", kind: .stderr)
                    continue
                }
                switch WorkspaceParser.applyEdit(to: file.content, payload: payload) {
                case .applied(let newContent):
                    file.content = newContent
                    file.isComplete = true
                    byPath[path] = file
                    sections.append("### edit \(path)\nOK — replaced 1 occurrence. The file is now \(file.lineCount) lines.")
                    WorkspaceRunner.shared.note("✓ edited \(path)\n", kind: .status)
                case .failed(let reason):
                    sections.append("### edit \(path)\nERROR: \(reason).")
                    WorkspaceRunner.shared.note("✗ edit \(path) failed\n", kind: .stderr)
                }

            case .run(let requestedPath):
                let entryPath = requestedPath ?? ordered.first { WorkspaceRunner.isRunnable($0) }
                guard let entryPath, let entry = byPath[entryPath] else {
                    sections.append("### run\nERROR: file not found: \(requestedPath ?? "(no path given, and no runnable file exists)")")
                    continue
                }
                guard WorkspaceRunner.isRunnable(entry.path) else {
                    sections.append("### run \(entry.path)\nERROR: can't run this file type. Runnable: .py .js .swift .rb .php .sh .zsh .pl .lua .go — websites preview automatically instead of running.")
                    continue
                }
                guard await confirmRunIfNeeded(path: entry.path) else {
                    sections.append("### run \(entry.path)\nSkipped — you didn't allow running generated code in this conversation.")
                    WorkspaceRunner.shared.note("✗ run \(entry.path) — not allowed\n", kind: .stderr)
                    continue
                }
                agentActivityText = "Running \(entry.path)…"
                defer { agentActivityText = nil }
                let snapshot = ordered.compactMap { byPath[$0] }
                let outcome = await WorkspaceRunner.shared.agentRun(
                    files: snapshot,
                    entry: entry,
                    workspaceKey: currentConversationId?.uuidString ?? "draft",
                    timeout: 60
                )
                // Tail the output so a chatty program can't blow up the
                // conversation's token budget.
                let tail = String(outcome.output.suffix(4000))
                var header = "### run \(entry.path)\nexit code: \(outcome.exitCode)"
                if outcome.timedOut { header += " (killed after 60s — programs must finish on their own)" }
                sections.append(header + "\noutput:\n" + (tail.isEmpty ? "(no output)" : tail))
                failureSignature = outcome.exitCode == 0
                    ? nil
                    : "\(entry.path)|\(outcome.exitCode)|\(String(tail.suffix(300)))"

            case .read(let path):
                guard let path, let file = byPath[path] else {
                    sections.append("### read \(path ?? "?")\nERROR: no such file. Files: \(ordered.joined(separator: ", "))")
                    continue
                }
                let capped = file.content.count > 12_000
                    ? String(file.content.prefix(12_000)) + "\n…(truncated)"
                    : file.content
                sections.append("### read \(path) (\(file.lineCount) lines)\n" + capped)
                WorkspaceRunner.shared.note("read \(path)\n", kind: .status)

            case .list:
                sections.append("### list files\n" + (ordered.isEmpty ? "(no files yet)" : ordered.joined(separator: "\n")))
                WorkspaceRunner.shared.note("listed files\n", kind: .status)

            case .mcpCall(let serverId, let tool, let argumentsJSON):
                guard let serverId, let tool else {
                    sections.append("### mcp\nERROR: missing server=\"...\" and/or tool=\"...\" attribute — e.g. ```eaon:mcp server=\"github\" tool=\"create_issue\"")
                    continue
                }
                guard let server = MCPCatalog.definition(for: serverId), MCPConnectionStore.shared.isConnected(serverId) else {
                    let connected = MCPConnectionStore.shared.connectedServers.map { "\"\($0.id)\"" }.joined(separator: ", ")
                    sections.append("### \(tool)\nERROR: \"\(serverId)\" isn't a connected service — nothing was called. The connected server ids are: \(connected.isEmpty ? "(none)" : connected).")
                    continue
                }
                // Validated locally against the tool's real schema BEFORE
                // the confirmation dialog or any network call — a model
                // that guessed a tool name or forgot a required argument
                // gets the exact spec back to self-correct with, and the
                // user is never asked to approve a call that's already
                // guaranteed to fail.
                guard let toolSpec = MCPConnectionStore.shared.tool(server: serverId, named: tool) else {
                    let available = MCPConnectionStore.shared.tools(for: serverId).map(\.name).joined(separator: ", ")
                    sections.append("### \(tool)\nERROR: \(server.displayName) has no tool named \"\(tool)\" — nothing was called. Its tools are exactly: \(available)")
                    continue
                }
                guard let arguments = Self.parseJSONObject(argumentsJSON) else {
                    sections.append("### \(tool)\nERROR: the block body wasn't a valid JSON object — nothing was called.\n\(toolSpec.detailedSpec)")
                    continue
                }
                let missing = toolSpec.requiredParameterNames.filter { arguments[$0] == nil }
                guard missing.isEmpty else {
                    sections.append("### \(tool)\nERROR: missing required argument\(missing.count == 1 ? "" : "s"): \(missing.joined(separator: ", ")) — nothing was called.\n\(toolSpec.detailedSpec)")
                    continue
                }
                guard await confirmMCPCallIfNeeded(server: server, tool: tool, argumentsJSON: argumentsJSON) else {
                    sections.append("### \(tool)\nSkipped — you didn't allow this action.")
                    WorkspaceRunner.shared.note("✗ \(server.displayName): \(tool) — not allowed\n", kind: .stderr)
                    continue
                }
                agentActivityText = "Running \(server.displayName): \(tool)…"
                defer { agentActivityText = nil }
                do {
                    let result = try await MCPConnectionStore.shared.callTool(server: serverId, name: tool, arguments: arguments)
                    if result.isError {
                        // Argument-shaped failures get the full spec so
                        // the retry is informed; other failures ("repo
                        // not found") don't need it. Checked against the
                        // untruncated text — the keyword search is cheap
                        // and shouldn't miss a match that happened to
                        // land past the cap.
                        let lowered = result.textSummary.lowercased()
                        let looksLikeArgumentError = ["param", "argument", "required", "invalid", "missing", "field", "schema"].contains { lowered.contains($0) }
                        let specSuffix = looksLikeArgumentError ? "\n\(toolSpec.detailedSpec)" : ""
                        sections.append("### \(tool)\nERROR (tool reported failure):\n\(Self.boundedToolResultText(result.textSummary))\(specSuffix)")
                        WorkspaceRunner.shared.note("✗ \(server.displayName): \(tool) — tool error\n", kind: .stderr)
                    } else {
                        sections.append("### \(tool)\nOK:\n\(Self.boundedToolResultText(result.textSummary))")
                        WorkspaceRunner.shared.note("✓ \(server.displayName): \(tool)\n", kind: .status)
                    }
                } catch {
                    sections.append("### \(tool)\nERROR: \(error.localizedDescription)")
                    WorkspaceRunner.shared.note("✗ \(server.displayName): \(tool) — \(error.localizedDescription)\n", kind: .stderr)
                }

            case .webSearch(let argumentsJSON):
                // Belt-and-suspenders: the teaching block and native tool
                // definition are both withheld once this is off (see
                // `systemPromptHistory` / `mergedNativeTools`), but a model
                // can still imitate the fence from its own conversation
                // history — refuse the call rather than silently searching
                // anyway after the user turned this off mid-conversation.
                guard WebSearchStore.shared.isEnabled else {
                    sections.append("### web search\nERROR: Web search is turned off (Settings → Privacy) — nothing was searched.")
                    continue
                }
                guard let arguments = Self.parseJSONObject(argumentsJSON),
                      let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty else {
                    sections.append("### web search\nERROR: missing a non-empty \"query\" string — nothing was searched. The block body must be JSON like {\"query\": \"...\"}")
                    continue
                }
                agentActivityText = "Searching the web for \"\(query)\"…"
                defer { agentActivityText = nil }
                do {
                    let results = try await WebSearchService.search(query: query)
                    sections.append("### web search: \(query)\n\(Self.boundedToolResultText(WebSearchService.formattedResultsForModel(results)))")
                    WorkspaceRunner.shared.note("✓ searched: \(query)\n", kind: .status)
                } catch {
                    sections.append("### web search: \(query)\nERROR: \(error.localizedDescription)")
                    WorkspaceRunner.shared.note("✗ search failed: \(query) — \(error.localizedDescription)\n", kind: .stderr)
                }

            case .computerCall(let toolName, let argumentsJSON):
                // Same belt-and-suspenders as web search: the teaching block
                // and native definitions are withheld outside the modes that
                // use them, but a model can still imitate the fence from
                // history — refuse rather than act. Device/coding calls run in
                // exactly two places: Eaon Claw (full catalog, capability
                // enabled) and the coding Agent (its focused subset). A call
                // replayed while the user is in plain Chat can't fire.
                let inClawExec = currentMode == .claw && DesktopControlStore.shared.isEnabled
                let inCodingAgentExec = currentMode == .agent
                guard inClawExec || inCodingAgentExec else {
                    sections.append("### computer\nERROR: this tool only runs in Eaon Claw (once enabled) or the coding Agent — nothing was done.")
                    continue
                }
                // In the coding Agent, keep the model on its own tools — a
                // replayed app/browser-driving fence from a past Claw chat
                // shouldn't execute here.
                if inCodingAgentExec, let toolName, let t = DesktopControlTool.tool(named: toolName), !DesktopTool.codingTools.contains(t) {
                    sections.append("### \(toolName)\nERROR: \"\(toolName)\" isn't one of the coding Agent's tools — use \(DesktopTool.codingTools.map(\.rawValue).joined(separator: ", ")).")
                    continue
                }
                guard let toolName else {
                    sections.append("### computer\nERROR: missing tool=\"...\" attribute — e.g. ```eaon:computer tool=\"list_directory\"")
                    continue
                }
                guard let tool = DesktopControlTool.tool(named: toolName) else {
                    let names = DesktopTool.allCases.map(\.rawValue).joined(separator: ", ")
                    sections.append("### \(toolName)\nERROR: no computer tool named \"\(toolName)\" — nothing was done. The tools are exactly: \(names)")
                    continue
                }
                guard let arguments = Self.parseJSONObject(argumentsJSON) else {
                    // The #1 cause, especially for write_file with real code:
                    // literal line breaks inside a JSON string. Say so
                    // explicitly and set a failure signature so the same
                    // mistake three times running stops the loop instead of
                    // grinding to a gateway 502.
                    let hint = tool == .writeFile
                        ? " For write_file, the whole file goes in \"content\" as ONE JSON string with every line break written as \\n (not a real newline), and inner quotes as \\\". Example: {\"path\": \"~/p/main.py\", \"content\": \"import sys\\nprint('hi')\\n\"}"
                        : " Put the arguments as one valid JSON object, escaping any newline inside a string as \\n."
                    sections.append("### \(toolName)\nERROR: the block body wasn't valid JSON — nothing was done.\(hint)")
                    failureSignature = "computer-badjson-\(toolName)"
                    continue
                }
                let missingArgs = tool.requiredParameterNames.filter { arguments[$0] == nil }
                guard missingArgs.isEmpty else {
                    sections.append("### \(toolName)\nERROR: missing required argument\(missingArgs.count == 1 ? "" : "s"): \(missingArgs.joined(separator: ", ")) — nothing was done.")
                    continue
                }
                guard await confirmDesktopCallIfNeeded(tool: tool, arguments: arguments) else {
                    sections.append("### \(toolName)\nSkipped — you didn't allow this action.")
                    WorkspaceRunner.shared.note("✗ computer: \(tool.displayName) — not allowed\n", kind: .stderr)
                    continue
                }
                agentActivityText = "Running \(tool.displayName)…"
                defer { agentActivityText = nil }
                let desktopResult = await DesktopControlService.execute(tool: tool, arguments: arguments)
                if desktopResult.isError {
                    sections.append("### \(toolName)\nERROR:\n\(Self.boundedToolResultText(desktopResult.text))")
                    WorkspaceRunner.shared.note("✗ computer: \(tool.displayName)\n", kind: .stderr)
                } else {
                    sections.append("### \(toolName)\nOK:\n\(Self.boundedToolResultText(desktopResult.text))")
                    WorkspaceRunner.shared.note("✓ computer: \(tool.displayName)\n", kind: .status)
                }
            }
        }

        guard !sections.isEmpty else { return nil }
        return AgentToolRun(
            results: "[Tool results — automated, not written by the user]\n\n" + sections.joined(separator: "\n\n"),
            failureSignature: failureSignature
        )
    }

    /// The system-message prefix for a request's history: the user's own
    /// custom instruction (Settings → Custom Instructions) if they've set
    /// one, then remembered facts (Settings → Memory) if that's turned on
    /// and there are any. Always the user's own words or things Eaon
    /// itself learned from them — never a hardcoded system prompt.
    private var systemPromptHistory: [HistoryTurn] {
        var entries: [HistoryTurn] = []
        let inClaw = currentMode == .claw && DesktopControlStore.shared.isEnabled

        // Eaon Claw's identity leads everything else. Placed first so a model
        // anchors on "I am an agent that controls this Mac" before it reads
        // any tool catalog — without it, a weaker model swamped by tools was
        // observed flatly denying it had any machine/browser access at all.
        if inClaw {
            entries.append(HistoryTurn(role: "system", content: Self.clawIdentityPreamble))
        }

        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            entries.append(HistoryTurn(role: "system", content: trimmed))
        }

        // The memory briefing — facts plus recent dated happenings, with
        // guidance to use them like a person would (follow up on how
        // something went) rather than recite them. Composed in
        // `MemoryStore.promptBlock`, which also handles the caps and the
        // 30-day event window so old happenings age out of prompts
        // naturally.
        if let memoryBlock = MemoryStore.shared.promptBlock() {
            entries.append(HistoryTurn(role: "system", content: memoryBlock))
        }

        // Chat's OWN dormant code-workspace feature (file explorer, editor,
        // console, live website preview — already fully built on the
        // execution side, see `WorkspaceParser`/`WorkspaceRunner`) had no
        // system prompt of its own at all, so a Chat-mode "make me a
        // website mockup" got zero guidance on how to present it — observed
        // live wandering toward "I'll use the deploy_to_vercel tool" instead
        // of just writing the code. Placed BEFORE the connected-services
        // catalog just below so a model anchors on "I can write real code
        // right here" before it reads about GitHub/Vercel/etc. — the same
        // primacy lesson already learned for Claw's identity preamble.
        if currentMode == .chat {
            entries.append(HistoryTurn(role: "system", content: WorkspaceParser.systemInstruction))
        }

        // Connected cloud plugins (GitHub, Notion, …) belong to Chat ONLY —
        // not the coding Agent, not Eaon Claw. Both of those are about *this
        // Mac*, and their tool sets are withheld from the native tools array
        // there (see `mergedNativeTools`); sending the plugin *catalog* in
        // the prompt anyway was a real bug — the model was told "you have
        // GitHub, Cloudflare, Supabase, Notion, Vercel" while those tools
        // weren't actually offered, and the catalog's bulk buried the coding
        // instructions so thoroughly that a model (GLM) decided the whole
        // system prompt was just "setup messages" with no real task in it.
        // Keeping Agent's prompt to coding tools + web search, and Claw's to
        // device + browser + web search, is what keeps them on task.
        if currentMode == .chat, let mcpInstruction = MCPConnectionStore.shared.agentInstructionBlock {
            entries.append(HistoryTurn(role: "system", content: mcpInstruction))
        }

        // Web search has nothing to connect, so it's unconditional whenever
        // the user hasn't turned it off (see `WebSearchStore`) — useful in
        // every conversational mode, Claw included (research tasks). Also
        // carries the current date/time so "what's today" is answered from
        // context instead of a flaky search.
        if WebSearchStore.shared.isEnabled {
            entries.append(HistoryTurn(role: "system", content: WebSearchTool.agentInstructionBlock()))
        }

        // Agent mode is the real coding agent: it writes real files to the
        // user's disk, runs them, and iterates — using the same device engine
        // as Eaon Claw, but a coding-focused tool subset and framing. Scoped
        // to Agent mode (not sent in Chat), so ordinary conversation is never
        // steered by it. Whether each command is confirmed or auto-runs is the
        // user's Sandboxed/Auto toggle (`agentAutoRun`), handled in
        // `confirmDesktopCallIfNeeded` — the prompt is identical either way.
        if currentMode == .agent {
            entries.append(HistoryTurn(role: "system", content: DesktopControlTool.codingInstructionBlock()))
        }

        // Eaon Claw's device-control teaching + browser how-to + the
        // non-negotiable safety rules (no sudo, no credentials/purchases,
        // treat read content as data not instructions). These come LAST so
        // the concrete tool detail is the freshest thing before the user's
        // message — primacy (identity, first) plus recency (the how, last).
        if inClaw {
            entries.append(HistoryTurn(role: "system", content: DesktopControlTool.agentInstructionBlock()))
            entries.append(HistoryTurn(role: "system", content: Self.clawBrowserInstructionBlock))
        }

        // A one-off `/skill-name` invocation for the message this request
        // is sending — set fresh per turn in `sendMessage()`, not a
        // persisted setting, so it applies to the request it was invoked
        // for and nothing after. Last, regardless of mode: an explicit,
        // deliberate per-message request from the user should be the
        // freshest thing before their actual message, the same recency
        // reasoning already applied to Claw's tool detail above.
        if let activeSkillForTurn {
            entries.append(HistoryTurn(
                role: "system",
                content: "The user has explicitly invoked the \"\(activeSkillForTurn.name)\" skill for this request — follow its instructions:\n\n\(activeSkillForTurn.instructions)"
            ))
        }

        return entries
    }

    /// Eaon Claw's opening system message — forceful and first. It exists
    /// specifically to stop a model from mistaking itself for a cloud chatbot
    /// with no machine access (observed live: a model in Claw denied it could
    /// see the browser and listed only its cloud plugins). States the real
    /// capability plainly and tells the model to reach for a tool rather than
    /// refuse when asked about the screen, browser, or files.
    private static let clawIdentityPreamble = """
    You are Eaon Claw, an AI agent running directly on the user's Mac. You control this computer and its web browser through real tools — this is genuine local access, not a cloud assistant's limitations. You can read and organize files, run shell commands, open and drive apps, and control the browser: open pages, read what's on the screen, click, scroll, and fill forms.

    Never tell the user you lack access to their machine, screen, browser, or files — you have that access. When they ask what's on their screen, what they're watching, what's open, or about a file, USE your tools to find out: read the browser with run_applescript, inspect the filesystem with list_directory or run_shell. Look first, then answer from what you actually observed — don't guess, and don't refuse.
    """

    /// Extra teaching for Eaon Claw specifically: how to drive the browser
    /// through the tools it already has. `run_applescript` can control Safari
    /// and Chrome (navigate, read the page, click, fill forms via JavaScript)
    /// and `open_url` opens a link in the default browser — but a model, and
    /// especially a smaller local one, won't reliably reach for AppleScript
    /// unless shown concretely how. Concrete, copy-pasteable examples make
    /// browser tasks actually work instead of the model guessing.
    private static let clawBrowserInstructionBlock = """
    Driving the browser is part of what you do, and most of it needs NO special setup.

    TO SEE WHAT'S OPEN — what page the user is on, what they're watching, which tabs are open — read the tab title and URL. This is the first thing to reach for, and it works with only the standard one-time permission (no developer settings). Use `run_applescript`:

    The active tab (Safari):
    ```eaon:computer tool="run_applescript"
    {"script": "tell application \\"Safari\\" to get {name, URL} of current tab of front window"}
    ```

    Every open tab (Safari):
    ```eaon:computer tool="run_applescript"
    {"script": "tell application \\"Safari\\" to get {name, URL} of every tab of front window"}
    ```

    The active tab (Google Chrome):
    ```eaon:computer tool="run_applescript"
    {"script": "tell application \\"Google Chrome\\" to get {title, URL} of active tab of front window"}
    ```

    Every open tab (Google Chrome):
    ```eaon:computer tool="run_applescript"
    {"script": "tell application \\"Google Chrome\\" to get {title, URL} of every tab of front window"}
    ```

    The tab title and URL usually already answer the question — a YouTube video's title, the show on Netflix, the article being read. Answer from them directly. If you don't know which browser is in front, try Chrome, then Safari.

    TO OPEN A PAGE — use `open_url`.

    TO READ THE FULL TEXT of a page, or to click or fill it — run JavaScript via `run_applescript`. This deeper control needs one extra one-time browser setting: "Allow JavaScript from Apple Events" (Safari → Settings → Advanced → "Show features for web developers", then Develop → Allow JavaScript from Apple Events; Chrome → View → Developer → Allow JavaScript from Apple Events). Only reach for this when the tab title and URL aren't enough.

    Read the visible text of the current Chrome tab:
    ```eaon:computer tool="run_applescript"
    {"script": "tell application \\"Google Chrome\\" to execute front window's active tab javascript \\"document.body.innerText\\""}
    ```

    Notes:
    - Prefer tab title/URL first — it answers most "what's open / what am I watching" questions with zero setup. Fall back to JavaScript only for full page content or clicking.
    - If a JavaScript call errors saying JavaScript is disabled, tell the user exactly how to turn on "Allow JavaScript from Apple Events" (above) — but first check whether the tab title and URL already answered them.
    - The same hard limits apply here as everywhere: never enter passwords, never buy anything or move money, never sign in on the user's behalf. If a task needs that, stop and hand it back to the user.
    """

    /// Builds one request-ready history turn from a chat message: real
    /// image parts for attachments the active model can actually see
    /// (`ModelCatalog.supportsVision`), and a plain "[Attached: x]"
    /// fallback note for anything it can't — a non-image file, or a model
    /// without vision. Shared by all three routing paths so the vision
    /// badge shown in the model picker and what actually gets sent never
    /// disagree with each other.
    private func historyTurn(for message: ChatMessage) -> HistoryTurn {
        let role = (message.isUser || message.isToolResult == true) ? "user" : "assistant"
        guard !message.attachments.isEmpty, ModelCatalog.supportsVision(for: selectedModel) else {
            return HistoryTurn(role: role, content: apiContent(for: message, sentImages: []))
        }

        var images: [HistoryImage] = []
        var sentImages: [MessageAttachment] = []
        for attachment in message.attachments where attachment.kind == .image {
            guard let image = ImagePayloadBuilder.build(for: attachment) else { continue }
            images.append(image)
            sentImages.append(attachment)
        }
        return HistoryTurn(role: role, content: apiContent(for: message, sentImages: sentImages), images: images)
    }

    /// Routes to a BYOK provider's own endpoint/format/key instead of Aqua.
    private func streamCustomCompletion(
        config: CustomProviderConfig,
        apiKey: String,
        typewriter: TypewriterStreamController,
        nativeTools: NativeToolConfig? = nil
    ) async throws {
        var history: [HistoryTurn] = systemPromptHistory
        history += messages.dropLast().map { historyTurn(for: $0) }
        try await CustomProviderAPIService().streamCompletion(
            config: config,
            apiKey: apiKey,
            modelId: selectedModel,
            history: history,
            typewriter: typewriter,
            nativeTools: nativeTools
        )
    }

    /// Routes to a local backend (Ollama / llama.cpp / MLX): makes sure its
    /// server is up (starting it, which on a first run may download the
    /// model), then streams over the same OpenAI-compatible wire code the
    /// BYOK path uses — local servers speak exactly that dialect (verified
    /// live against both Ollama and llama-server on this machine).
    private func streamLocalCompletion(record: LocalModelRecord, aiMsgId: UUID, typewriter: TypewriterStreamController, nativeTools: NativeToolConfig? = nil) async throws {
        // A real pre-flight check, not a guess: Ollama runs independent of
        // this app, so it merely being reachable says nothing about whether
        // *this* model is already resident — only `/api/ps` does. llama.cpp/
        // MLX are spawned by this app, so "already the active spawned
        // process" is the equivalent real check there.
        let wasAlreadyWarm: Bool
        switch record.backend {
        case .ollama:
            wasAlreadyWarm = await LocalAIManager.shared.ollamaModelStatus(record.requestModelId) != nil
        case .llamaCpp, .mlx:
            wasAlreadyWarm = LocalAIManager.shared.activeSpawned?.modelId == record.id
        }

        // llama.cpp/MLX already surface their own real, live status via
        // `LocalAIManager.isStartingServer`/`startupStatus` while
        // `ensureReady` spawns and waits below — only Ollama needs its own
        // text here, since its server being reachable at all says nothing
        // about this specific model still needing to load.
        if !wasAlreadyWarm, record.backend == .ollama {
            loadingStatusText = "Loading \(record.displayName) into memory — first response can take a few seconds…"
        }

        let loadStart = Date()
        let baseURL = try await LocalAIManager.shared.ensureReady(for: record)
        // For llama.cpp/MLX, everything up to here — spawning the server and
        // waiting for it to answer healthy — *is* the load, fully separate
        // from generation, so this is a precise, real duration. For Ollama,
        // the model only actually loads inside the generate call itself, so
        // this same span can't be used the same way — handled below.
        let llamaCppMlxLoadDuration = Date().timeIntervalSince(loadStart)

        var history: [HistoryTurn] = systemPromptHistory
        history += messages.dropLast().map { historyTurn(for: $0) }
        // Local servers render the model's own embedded chat template,
        // which is frequently strict about history shape — see
        // `flattenedForStrictChatTemplates`' own doc for the live failure
        // this prevents. Cloud paths deliberately don't do this.
        history = history.flattenedForStrictChatTemplates

        let ephemeralConfig = CustomProviderConfig(
            brand: ModelCatalog.brand(for: record.requestModelId),
            baseURL: baseURL.absoluteString,
            format: .openAICompatible,
            modelIDs: [record.requestModelId]
        )
        try await CustomProviderAPIService().streamCompletion(
            config: ephemeralConfig,
            apiKey: "local-no-key",
            modelId: record.requestModelId,
            history: history,
            typewriter: typewriter,
            // Local servers (Ollama/llama.cpp) accept the tools parameter
            // for tool-trained models; the service retries without it for
            // models that reject it, so this can't break plain local chat.
            nativeTools: nativeTools
        )

        loadingStatusText = nil
        guard let index = messages.firstIndex(where: { $0.id == aiMsgId }) else { return }
        messages[index].wasColdLoad = !wasAlreadyWarm
        if !wasAlreadyWarm, record.backend != .ollama {
            messages[index].coldLoadDurationSeconds = llamaCppMlxLoadDuration
        }
        if record.backend == .ollama, let status = await LocalAIManager.shared.ollamaModelStatus(record.requestModelId) {
            messages[index].localMemoryBytes = status.sizeVRAMBytes
            // The completion above just streamed through the OpenAI-compat
            // endpoint, which silently ignores keep_alive and leaves Ollama
            // at its own hardcoded 5-minute default — this re-asserts the
            // user's actual configured idle window so it's not quietly
            // overridden by every real chat turn.
            Task {
                await LocalAIManager.shared.primeOllamaModel(
                    record.requestModelId,
                    keepAlive: LocalAIManager.shared.ollamaKeepAliveDuration.rawValue
                )
            }
        }
    }

    /// `sentImages` — attachments already carried as real image parts on
    /// this same turn — are excluded from the fallback note; everything
    /// else (non-image files, or images the active model can't see)
    /// still gets the plain "[Attached: x]" text so nothing is silently
    /// dropped.
    private func apiContent(for message: ChatMessage, sentImages: [MessageAttachment]) -> String {
        // A reasoning model's <think> spans belong to the turn they were
        // produced in — sending them back in history bloats every request
        // and, worse, shows the model its own past formatting mistakes as
        // precedent to imitate (the glued `</think>```eaon:` habit compounds
        // turn over turn). Every reasoning-model vendor's guidance is the
        // same: strip prior thinking from history. Display is untouched —
        // the saved message keeps its spans; this only shapes what's sent.
        let raw = message.isUser || message.isToolResult == true
            ? message.content
            : WorkspaceParser.strippedOfThinking(message.content)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = message.attachments.filter { attachment in
            !sentImages.contains { $0.id == attachment.id }
        }
        guard !remaining.isEmpty else { return text }

        let attachmentNote = attachmentFallbackText(for: remaining)
        if text.isEmpty { return attachmentNote }
        return text + "\n\n" + attachmentNote
    }

    private func attachmentFallbackText(for attachments: [MessageAttachment]) -> String {
        let names = attachments.map(\.fileName).joined(separator: ", ")
        return "[Attached: \(names)]"
    }

    private func streamCompletion(
        apiKey: String,
        aiMessageId: UUID,
        typewriter: TypewriterStreamController,
        nativeTools: NativeToolConfig? = nil
    ) async throws {
        var request = URLRequest(url: AquaAPI.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        var apiMessages: [[String: Any]] = systemPromptHistory.map(\.openAICompatibleJSON)
        apiMessages += messages.dropLast().map { historyTurn(for: $0).openAICompatibleJSON }

        var body: [String: Any] = [
            "model": selectedModel,
            "messages": apiMessages,
            "stream": true,
        ]
        if let nativeTools {
            body["tools"] = nativeTools.tools
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, httpResponse) = try await TransientHTTPRetry.send(request)

        if httpResponse.statusCode != 200 {
            let errorBody = try await readErrorBody(from: bytes)
            // Same safeguard as the BYOK path: a backend/model that
            // rejects the tools parameter must not break chat — retry
            // once without it; the fenced-markup channel still works.
            if nativeTools != nil, (400...422).contains(httpResponse.statusCode), errorBody.lowercased().contains("tool") {
                try await streamCompletion(apiKey: apiKey, aiMessageId: aiMessageId, typewriter: typewriter, nativeTools: nil)
                return
            }
            throw APIClientError.httpError(status: httpResponse.statusCode, message: errorBody)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        if contentType.contains("text/event-stream") || contentType.contains("application/x-ndjson") {
            try await consumeStream(bytes, typewriter: typewriter, nativeTools: nativeTools)
            return
        }

        // Some responses may return a single JSON payload instead of SSE chunks.
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
        }

        if let json = try? JSONSerialization.jsonObject(with: collected) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            var sawAny = false
            let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String)
            if let reasoning, !reasoning.isEmpty {
                sawAny = true
                typewriter.append("<think>\(reasoning)</think>")
                StatisticsTracker.shared.recordGeneratedCharacters(reasoning.count)
            }
            if let content = message["content"] as? String, !content.isEmpty {
                sawAny = true
                typewriter.append(content)
                StatisticsTracker.shared.recordGeneratedCharacters(content.count)
            }
            if let nativeTools, let calls = message["tool_calls"] as? [[String: Any]] {
                var accumulator = ToolCallAccumulator()
                accumulator.ingest(complete: calls)
                if let fences = accumulator.fencedBlocks(nameMap: nativeTools.nameMap) {
                    sawAny = true
                    typewriter.append(fences)
                }
            }
            if sawAny { return }
        }

        let fallbackText = String(data: collected, encoding: .utf8) ?? "Unexpected response from Aqua API."
        throw APIClientError.unexpectedResponse(fallbackText)
    }

    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        typewriter: TypewriterStreamController,
        nativeTools: NativeToolConfig? = nil
    ) async throws {
        var toolCalls = ToolCallAccumulator()
        let reasoningBridge = ReasoningDeltaBridge()
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }

            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                continue
            }

            toolCalls.ingest(delta: delta)

            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
            guard let combined = reasoningBridge.text(reasoning: reasoning, content: delta["content"] as? String) else { continue }
            typewriter.append(combined)
            StatisticsTracker.shared.recordGeneratedCharacters(combined.count)
        }

        if let closing = reasoningBridge.closeIfNeeded() {
            typewriter.append(closing)
        }

        // Native calls become eaon:mcp fences on the same message — one
        // downstream pipeline for both calling channels.
        if let nativeTools, let fences = toolCalls.fencedBlocks(nameMap: nativeTools.nameMap) {
            typewriter.append(fences)
        }

        if !typewriter.hasContent {
            throw APIClientError.emptyResponse
        }
    }

    /// Floor between streaming workspace re-derivations — see
    /// `setAssistantMessageContent`. 10Hz is visually indistinguishable
    /// from per-tick for a typing effect, and the final exact state is
    /// guaranteed regardless by the unconditional
    /// `refreshWorkspace(streaming: false)` in `sendMessage`'s epilogue.
    private var lastStreamingWorkspaceRefresh = Date.distantPast

    private func setAssistantMessageContent(id: UUID, content: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = content
        // Real content arriving means any local-model load is over — clear
        // the loading text right away rather than waiting for the whole
        // response to finish.
        if !content.isEmpty { loadingStatusText = nil }
        // Live-update the workspace as file blocks stream in, so code types
        // into the panel's editor in real time. Throttled to 10Hz: this
        // callback fires on EVERY typewriter tick (as often as every ~3ms
        // under backlog), and `files(fromMessages:)` re-line-scans every
        // fence-carrying message in the conversation each call — measured
        // as a major share of the full-core burn during agent streaming.
        if WorkspaceParser.mightContainFiles(content) {
            let now = Date()
            if now.timeIntervalSince(lastStreamingWorkspaceRefresh) >= 0.1 {
                lastStreamingWorkspaceRefresh = now
                refreshWorkspace(streaming: true)
            }
        }
    }

    private func finalizeGeneration(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let end = Date()
        messages[index].generationEndTime = end
        let chars = messages[index].content.count
        let approxTok = max(1, Int(ceil(Double(chars) / 4.0)))
        messages[index].generatedTokenCount = approxTok

        // Record speed sample for leaderboard
        if let start = messages[index].generationStartTime, approxTok > 10 {
            let latency = end.timeIntervalSince(start)
            let tps = latency > 0 ? Double(approxTok) / latency : 0
            let modelId = messages[index].modelId ?? selectedModel
            if !modelId.isEmpty {
                StatisticsTracker.shared.recordCompletionSpeed(
                    modelId: modelId,
                    tokensPerSecond: tps,
                    latency: latency,
                    tokenCount: approxTok
                )
            }
        }
    }

    private func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
        }
        if let json = try? JSONSerialization.jsonObject(with: collected) as? [String: Any],
           let detail = json["detail"] as? String {
            return detail
        }
        return String(data: collected, encoding: .utf8) ?? "Unknown error"
    }

    private func appendSystemError(_ text: String) {
        messages.append(ChatMessage(content: text, isUser: false, isError: true))
        saveMessages()
    }

    private func markError(id: UUID, text: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = text
            messages[index].isError = true
        } else {
            appendSystemError(text)
        }
        saveMessages()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }
}

enum APIClientError: LocalizedError {
    case httpError(status: Int, message: String)
    case unexpectedResponse(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let message):
            let base = "API error (\(status)): \(message)"
            // 5xx (incl. Cloudflare's 52x) is an upstream/gateway failure —
            // the request never reached a healthy model. It's the provider
            // having a temporary problem with THIS model, not something the
            // user got wrong or can fix by re-sending the same thing, so
            // point them at the remedy that actually works: another model.
            // (Verified 2026-07-10: deepseek-v4-pro was 502ing on Aqua for
            // every request while other models answered normally.)
            if (500...599).contains(status) {
                return base + "\n\nThis usually means the provider is having a temporary problem with this model — not something on your end. Try again in a moment, or switch to a different model from the menu above."
            }
            return base
        case .unexpectedResponse(let message):
            return message
        case .emptyResponse:
            return "The model returned an empty response. Try another model."
        }
    }
}

/// Shared by every streaming path (Aqua, BYOK, local). 502/503/504 are
/// classic gateway hiccups — an upstream restarting, a momentary overload
/// behind a proxy — not something the request or the user got wrong, and
/// they showed up reliably right after a tool call: the follow-up request
/// (now carrying the tool's results, and the `tools` schema on every
/// turn) is larger and slower than a bare chat message, which is exactly
/// the shape of request a flaky gateway drops. Retried automatically
/// with backoff before ever reaching the user — dying on the first one
/// is what turned "brief blip" into "the model quit."
///
/// Deliberately scoped to ONLY the initial request + status line — never
/// wraps stream-body reading. A 502 that somehow arrived mid-stream is
/// NOT retried here, since replaying the whole request could duplicate
/// tokens already appended to the typewriter.
enum TransientHTTPRetry {
    private static let retryableStatuses: Set<Int> = [502, 503, 504]

    /// Backoff before attempt N (1-indexed gap): 400ms, 800ms, 1.6s, 3.2s —
    /// exponential, capped. Chosen after watching Aqua's gateway alternate
    /// 502 and 200 on the *same* request within a couple of seconds during a
    /// real origin flap: three quick tries (the old ~1.5s total) fell inside
    /// that window and surfaced a hard error the very next retry would have
    /// cleared. Five tries spanning ~6s ride the flap out invisibly, while a
    /// genuinely sustained outage still ends in the real error rather than
    /// hanging the user indefinitely.
    private static func backoffMilliseconds(beforeAttempt attempt: Int) -> Int {
        min(3200, 400 * (1 << (attempt - 1)))
    }

    static func send(_ request: URLRequest, maxAttempts: Int = 5) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var attempt = 1
        while true {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard retryableStatuses.contains(http.statusCode), attempt < maxAttempts else {
                return (bytes, http)
            }
            try? await Task.sleep(for: .milliseconds(backoffMilliseconds(beforeAttempt: attempt)))
            attempt += 1
        }
    }

    /// Non-streaming twin of `send`, for plain request/response calls like
    /// the model-list fetch — which had no retry at all, so a single gateway
    /// blip during a flap left the model picker empty even though the very
    /// next request would have loaded it.
    static func sendData(_ request: URLRequest, maxAttempts: Int = 5) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard retryableStatuses.contains(http.statusCode), attempt < maxAttempts else {
                return (data, http)
            }
            try? await Task.sleep(for: .milliseconds(backoffMilliseconds(beforeAttempt: attempt)))
            attempt += 1
        }
    }
}
