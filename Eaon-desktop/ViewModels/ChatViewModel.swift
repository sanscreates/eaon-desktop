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
    var availableModels: [APIModel] = []
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
    var pendingAttachments: [MessageAttachment] = []
    var composerNotice: String?

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
        return aquaModels + customModels + localModels
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
    /// tool loop from re-posting the conversation forever.
    private static let maxAgentSteps = 16

    func recordPreviewRuntimeError(_ text: String) {
        let trimmed = String(text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pendingPreviewErrors.count < 5, !pendingPreviewErrors.contains(trimmed) else { return }
        pendingPreviewErrors.append(trimmed)
        WorkspaceRunner.shared.note("preview error: \(trimmed)\n", kind: .stderr)
    }

    private let apiService = AquaAPIService()
    private static let selectedModelKey = "selected_model_id"
    private static let customInstructionsKey = "custom_instructions"
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
        KeychainService.migrateLegacyKeyIfNeeded()
        if let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey) {
            selectedModel = saved
        }
        customInstructions = UserDefaults.standard.string(forKey: Self.customInstructionsKey) ?? ""
        loadConversations()
        loadProjects()
        refreshContextLimit()

        // No point calling an API that's guaranteed to reject an absent key —
        // onboarding triggers the first real fetch once a key is saved.
        if KeychainService.hasAPIKey {
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
            conversations[index].messages = messages
            conversations[index].updatedAt = Date()
            if conversations[index].title == Conversation.placeholderTitle() {
                conversations[index].title = Self.deriveTitle(from: messages)
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
            availableModels = try await apiService.fetchModels()
            reconcileSelectedModel()
        } catch {
            availableModels = []
            modelsLoadError = error.localizedDescription
            print("Failed to fetch models: \(error)")
        }

        // Refresh what's runnable locally alongside the remote catalog.
        await LocalAIManager.shared.refreshOllamaModels()
        reconcileSelectedModel()

        isLoadingModels = false
    }

    func selectModel(_ modelId: String) {
        selectedModel = modelId
        UserDefaults.standard.set(modelId, forKey: Self.selectedModelKey)
        warmIfLocalOllama(modelId)
        refreshContextLimit()
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

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard (!text.isEmpty || !attachments.isEmpty), !isGenerating else { return }

        guard !selectedModel.isEmpty, chatModels.contains(where: { $0.id == selectedModel }) else {
            appendSystemError("No chat model selected. Wait for models to load from the Aqua API, then pick one from the menu.")
            return
        }

        // Routing precedence: BYOK config → local model (Ollama/llama.cpp/
        // MLX, no key at all) → Aqua.
        let customConfig = CustomProviderStore.shared.config(owning: selectedModel)
        let localRecord = customConfig == nil ? LocalAIManager.shared.record(withId: selectedModel) : nil

        let apiKey: String
        if let customConfig {
            guard let customKey = CustomProviderStore.shared.apiKey(for: customConfig.id), !customKey.isEmpty else {
                appendSystemError("No API key saved for \(customConfig.brand.companyName). Add one in Settings → Custom Providers.")
                return
            }
            apiKey = customKey
        } else if localRecord != nil {
            // Local servers don't authenticate; they ignore the header.
            apiKey = "local-no-key"
        } else {
            guard let aquaKey = KeychainService.loadAPIKey(), !aquaKey.isEmpty else {
                appendSystemError("Add your Aqua API key in Settings → Aqua API to start chatting.")
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                return
            }
            apiKey = aquaKey
        }

        let userMsg = ChatMessage(content: text, isUser: true, attachments: attachments)
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

        for step in 1...Self.maxAgentSteps {
            let outcome = await streamOneAgentStep(customConfig: customConfig, localRecord: localRecord, apiKey: apiKey)
            guard case .completed(let replyText) = outcome, !Task.isCancelled else { break }

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
            if step == Self.maxAgentSteps {
                WorkspaceRunner.shared.note("● Agent paused after \(Self.maxAgentSteps) rounds — send a message to continue.\n", kind: .status)
            }
        }

        self.typewriter = nil
        self.generationTask = nil
        activeTypingMessageId = nil
        isGenerating = false
        StatisticsTracker.shared.currentGeneratingModel = ""
        refreshWorkspace(streaming: false)
    }

    private enum AgentStepOutcome {
        case completed(String)
        case cancelled
        case failed
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

        var outcome: AgentStepOutcome
        do {
            if let customConfig {
                try await streamCustomCompletion(config: customConfig, apiKey: apiKey, typewriter: typewriter)
            } else if let localRecord {
                try await streamLocalCompletion(record: localRecord, aiMsgId: aiMsgId, typewriter: typewriter)
            } else {
                try await streamCompletion(apiKey: apiKey, aiMessageId: aiMsgId, typewriter: typewriter)
            }
            typewriter.markStreamFinished()
            await typewriter.waitUntilCaughtUp()
            finalizeGeneration(id: aiMsgId)
            saveMessages()
            outcome = .completed(messages.first(where: { $0.id == aiMsgId })?.content ?? "")
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

    /// Executes the run/edit/read/ls tools a reply requested, against a
    /// working snapshot that replays the reply's own events in order — so
    /// each tool sees exactly the file state the model had produced by that
    /// point. Returns nil when the reply requested nothing (loop ends).
    private func executeAgentTools(inReplyText replyText: String) async -> AgentToolRun? {
        let events = WorkspaceParser.events(from: replyText)
        let hasActions = events.contains { event in
            if case .write = event { return false }
            return true
        }
        guard hasActions else { return nil }

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
            }
        }

        guard !sections.isEmpty else { return nil }
        return AgentToolRun(
            results: "[Tool results — automated, not written by the user]\n\n" + sections.joined(separator: "\n\n"),
            failureSignature: failureSignature
        )
    }

    /// The system-message prefix for a request's history — the user's own
    /// custom instruction (Settings → Custom Instructions) if they've set
    /// one, empty otherwise. The only system-prompt injection this app
    /// does, and it's always the user's own words, never a hardcoded one.
    private var customInstructionHistory: [(role: String, content: String)] {
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [(role: "system", content: trimmed)]
    }

    /// Routes to a BYOK provider's own endpoint/format/key instead of Aqua.
    private func streamCustomCompletion(
        config: CustomProviderConfig,
        apiKey: String,
        typewriter: TypewriterStreamController
    ) async throws {
        var history: [(role: String, content: String)] = customInstructionHistory
        history += messages.dropLast().map {
            // Tool results ride back to the model as user turns.
            (role: ($0.isUser || $0.isToolResult == true) ? "user" : "assistant", content: apiContent(for: $0))
        }
        try await CustomProviderAPIService().streamCompletion(
            config: config,
            apiKey: apiKey,
            modelId: selectedModel,
            history: history,
            typewriter: typewriter
        )
    }

    /// Routes to a local backend (Ollama / llama.cpp / MLX): makes sure its
    /// server is up (starting it, which on a first run may download the
    /// model), then streams over the same OpenAI-compatible wire code the
    /// BYOK path uses — local servers speak exactly that dialect (verified
    /// live against both Ollama and llama-server on this machine).
    private func streamLocalCompletion(record: LocalModelRecord, aiMsgId: UUID, typewriter: TypewriterStreamController) async throws {
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

        var history: [(role: String, content: String)] = customInstructionHistory
        history += messages.dropLast().map {
            (role: ($0.isUser || $0.isToolResult == true) ? "user" : "assistant", content: apiContent(for: $0))
        }

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
            typewriter: typewriter
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

    private func apiContent(for message: ChatMessage) -> String {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.attachments.isEmpty else { return text }

        let attachmentNote = attachmentFallbackText(for: message.attachments)
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
        typewriter: TypewriterStreamController
    ) async throws {
        var request = URLRequest(url: AquaAPI.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedInstructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var apiMessages: [[String: String]] = trimmedInstructions.isEmpty
            ? []
            : [["role": "system", "content": trimmedInstructions]]
        apiMessages += messages.dropLast().map {
            [
                // Tool results ride back to the model as user turns.
                "role": ($0.isUser || $0.isToolResult == true) ? "user" : "assistant",
                "content": apiContent(for: $0),
            ]
        }

        let body: [String: Any] = [
            "model": selectedModel,
            "messages": apiMessages,
            "stream": true,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 {
            let errorBody = try await readErrorBody(from: bytes)
            throw APIClientError.httpError(status: httpResponse.statusCode, message: errorBody)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        if contentType.contains("text/event-stream") || contentType.contains("application/x-ndjson") {
            try await consumeStream(bytes, typewriter: typewriter)
            return
        }

        // Some responses may return a single JSON payload instead of SSE chunks.
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
        }

        if let json = try? JSONSerialization.jsonObject(with: collected) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            typewriter.append(content)
            StatisticsTracker.shared.recordGeneratedCharacters(content.count)
            return
        }

        let fallbackText = String(data: collected, encoding: .utf8) ?? "Unexpected response from Aqua API."
        throw APIClientError.unexpectedResponse(fallbackText)
    }

    private func consumeStream(_ bytes: URLSession.AsyncBytes, typewriter: TypewriterStreamController) async throws {
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }

            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }

            typewriter.append(content)
            StatisticsTracker.shared.recordGeneratedCharacters(content.count)
        }

        if !typewriter.hasContent {
            throw APIClientError.emptyResponse
        }
    }

    private func setAssistantMessageContent(id: UUID, content: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = content
        // Real content arriving means any local-model load is over — clear
        // the loading text right away rather than waiting for the whole
        // response to finish.
        if !content.isEmpty { loadingStatusText = nil }
        // Live-update the workspace as file blocks stream in, so code types
        // into the panel's editor in real time.
        if WorkspaceParser.mightContainFiles(content) {
            refreshWorkspace(streaming: true)
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
            return "API error (\(status)): \(message)"
        case .unexpectedResponse(let message):
            return message
        case .emptyResponse:
            return "The model returned an empty response. Try another model."
        }
    }
}
