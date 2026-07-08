import AppKit
import SwiftUI

private let conversationMaxWidth: CGFloat = 768

struct ChatHomeView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var viewModel: ChatViewModel
    /// Whether the sidebar is currently hidden — with no rail left reserving
    /// space in that corner, the top bar itself has to clear the traffic
    /// lights and offer a way to bring the sidebar back.
    var isSidebarCollapsed: Bool = false
    var onExpandSidebar: () -> Void = {}
    /// Lets the model picker's per-provider gear icon open Settings landed
    /// directly on that provider's own page.
    var onOpenProviderSettings: (String) -> Void = { _ in }

    @State private var showingShareSheet = false

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if viewModel.messages.isEmpty {
                emptyState
            } else {
                conversation
            }
        }
        .background(colors.backgroundPrimary)
        .overlay {
            if showingShareSheet, let conversation = currentConversation {
                ShareChatSheet(conversation: conversation, isPresented: $showingShareSheet)
            }
        }
    }

    private var currentConversation: Conversation? {
        Conversation(
            title: viewModel.conversations.first { $0.id == viewModel.currentConversationId }?.title ?? "New chat",
            messages: viewModel.messages
        )
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            if isSidebarCollapsed {
                // Clears the traffic lights — with the sidebar hidden there's
                // no rail reserving this corner for them anymore, so the top
                // bar has to leave the room itself instead of sitting under
                // them. Also the only way back to the full sidebar now that
                // there's no persistent rail icon for it.
                Spacer().frame(width: 80)
                TopBarIconButton(systemName: "sidebar.left", label: nil) {
                    onExpandSidebar()
                }
                .help("Show sidebar")
            }

            // Leading, right next to the sidebar's edge — not centered.
            ModelPickerMenu(viewModel: viewModel, onOpenProviderSettings: onOpenProviderSettings)

            if !viewModel.messages.isEmpty { ContextUsageBadge(viewModel: viewModel) }

            Spacer(minLength: 0)

            // Reopen the coding workspace when this chat has files but the
            // panel was closed.
            if !viewModel.workspaceFiles.isEmpty {
                TopBarIconButton(systemName: "chevron.left.forwardslash.chevron.right", label: nil) {
                    if viewModel.isWorkspaceOpen {
                        viewModel.closeWorkspace()
                    } else {
                        viewModel.openWorkspace()
                    }
                }
            }

            if !viewModel.messages.isEmpty {
                TopBarIconButton(systemName: "square.and.arrow.up", label: nil) {
                    showingShareSheet = true
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        // Match the sidebar card's 10pt top inset so the picker sits on the
        // same line as the traffic lights / sidebar header controls.
        .padding(.top, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("What can I help with?")
                .font(AppFont.mono(34, weight: .bold))
                .foregroundStyle(colors.textPrimary)
                .padding(.bottom, 26)

            ChatComposer(viewModel: viewModel)
                .frame(maxWidth: conversationMaxWidth)
                .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 24) {
                        ForEach(viewModel.messages) { message in
                            MessageCell(
                                message: message,
                                isActivelyTyping: viewModel.activeTypingMessageId == message.id,
                                onRegenerate: { viewModel.startSend() },
                                onOpenWorkspaceFile: { viewModel.openWorkspace(selecting: $0) },
                                loadingStatusText: viewModel.activeTypingMessageId == message.id ? viewModel.loadingStatusText : nil
                            )
                            .id(message.id)
                        }
                        Color.clear.frame(height: 8).id(bottomAnchor)
                    }
                    .frame(maxWidth: conversationMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .onChange(of: viewModel.messages.last?.content) { _, _ in scrollToBottom(proxy) }
                .onChange(of: viewModel.messages.count) { _, _ in scrollToBottom(proxy) }
                .onAppear { scrollToBottom(proxy, animated: false) }
            }

            VStack(spacing: 6) {
                ChatComposer(viewModel: viewModel)
                    .frame(maxWidth: conversationMaxWidth)

                Text("Eaon can make mistakes. Check important info.")
                    .font(AppFont.sans(11))
                    .foregroundStyle(colors.textTertiary)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .background(colors.backgroundPrimary)
        }
    }

    private let bottomAnchor = "aqua-bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }
}

/// How full the current conversation is relative to the active model's
/// context window — approximate (see `ContextWindowEstimator`), so it
/// reads as a rough gauge, not a precise measurement. Silent (renders
/// nothing) whenever the limit isn't known or usage is negligible, rather
/// than showing a guessed or misleadingly-precise number.
private struct ContextUsageBadge: View {
    @Environment(\.themeColors) private var colors
    @Bindable var viewModel: ChatViewModel

    private var label: String? {
        guard let limit = viewModel.contextLimitTokens else { return nil }
        return ContextWindowEstimator.usageLabel(usedTokens: viewModel.estimatedUsedTokens, limitTokens: limit)
    }

    private var percent: Double {
        guard let limit = viewModel.contextLimitTokens, limit > 0 else { return 0 }
        return Double(viewModel.estimatedUsedTokens) / Double(limit)
    }

    private var tint: Color {
        if percent >= 0.9 { return colors.destructive }
        if percent >= 0.75 { return .orange }
        return colors.textTertiary
    }

    var body: some View {
        if let label {
            Text(label)
                .font(AppFont.mono(11, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(colors.backgroundChip.opacity(0.6)))
                .help("Roughly \(viewModel.estimatedUsedTokens) of \(viewModel.contextLimitTokens ?? 0) tokens — estimated from character count, not an exact count")
        }
    }
}

// MARK: - Top bar components

struct TopBarIconButton: View {
    @Environment(\.themeColors) private var colors
    let systemName: String
    var label: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
                if let label {
                    Text(label).font(AppFont.mono(13, weight: .medium))
                }
            }
            .foregroundStyle(colors.textPrimary.opacity(0.85))
            .padding(.horizontal, label == nil ? 8 : 12)
            .frame(height: 34)
            .background(
                Capsule().fill(isHovered ? colors.backgroundHover : .clear)
            )
            .overlay(
                Capsule().stroke(colors.borderSubtle, lineWidth: label == nil ? 0 : 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Message cell

struct MessageCell: View {
    @Environment(\.themeColors) private var colors
    let message: ChatMessage
    var isActivelyTyping: Bool = false
    var onRegenerate: () -> Void = {}
    var onOpenWorkspaceFile: ((String) -> Void)? = nil
    /// Set by the caller only for the message currently streaming, from
    /// `ChatViewModel.loadingStatusText` — real status text for an Ollama
    /// model still loading. Ollama's server runs independent of this app
    /// and stays reachable regardless of whether *this* model is loaded, so
    /// this can't be derived locally the way the llama.cpp/MLX case below
    /// can; `ChatViewModel` already did the real pre-flight check.
    var loadingStatusText: String? = nil

    private var fontSize: CGFloat { AppearanceSettings.shared.fontSize.messageFontSize }

    /// Merges the two real local-loading signals into one: `loadingStatusText`
    /// (passed in, Ollama's case) and `LocalAIManager`'s own live spawn
    /// status (read directly here — llama.cpp/MLX are spawned by this app,
    /// so their loading state is already tracked and doesn't need passing
    /// in). Only one is ever relevant for a given local backend at once.
    private var liveLoadingText: String? {
        guard isActivelyTyping else { return nil }
        if LocalAIManager.shared.isStartingServer {
            return LocalAIManager.shared.startupStatus ?? "Starting the local server…"
        }
        return loadingStatusText
    }

    /// A completed local-or-not message's real generation stats — nil for
    /// anything still typing, an error, a tool-result card, or a message
    /// with no timing data (e.g. one loaded from before this feature
    /// existed). Every number here is measured, never estimated.
    private var statsCaption: String? {
        guard !message.isUser, message.isToolResult != true, !message.isError else { return nil }
        guard let modelId = message.modelId, !modelId.isEmpty else { return nil }
        guard let start = message.generationStartTime, let end = message.generationEndTime,
              message.generatedTokenCount > 0 else { return nil }

        var parts: [String] = []

        if LocalAIManager.shared.owns(modelId) {
            let backendName = LocalAIManager.shared.record(withId: modelId)?.backend.displayName ?? "this Mac"
            parts.append("Ran locally · \(backendName)")
        }

        parts.append("\(message.generatedTokenCount) tok")
        let duration = end.timeIntervalSince(start)
        if duration > 0 {
            let tokensPerSecond = Double(message.generatedTokenCount) / duration
            parts.append(String(format: "%.0f tok/s", tokensPerSecond))
        }

        if let loadSeconds = message.coldLoadDurationSeconds {
            parts.append(String(format: "loaded in %.1fs", loadSeconds))
        } else if message.wasColdLoad == true {
            // Real fact (a fresh load did happen), just without a precise
            // duration to show — see `ChatMessage.coldLoadDurationSeconds`.
            parts.append("model was loading")
        }

        if let bytes = message.localMemoryBytes, bytes > 0 {
            let gigabytes = Double(bytes) / 1_000_000_000
            parts.append(String(format: "%.1f GB in memory", gigabytes))
        }

        return parts.joined(separator: " · ")
    }

    private var userBubbleFill: Color {
        AppearanceSettings.shared.coloredUserBubble
            ? AppearanceSettings.shared.accentColor.opacity(0.15)
            : colors.userBubble
    }

    var body: some View {
        if message.isToolResult == true {
            ToolResultsCard(content: message.content)
        } else if message.isUser {
            userMessage
        } else {
            assistantMessage
        }
    }

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.attachments.isEmpty {
                    MessageAttachmentsView(attachments: message.attachments)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(AppFont.sans(fontSize))
                        .foregroundStyle(colors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(userBubbleFill)
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var assistantMessage: some View {
        if message.isError {
            errorMessage
        } else {
            HoverRevealAssistantBody(
                content: message.content,
                isActivelyTyping: isActivelyTyping,
                onRegenerate: onRegenerate,
                onOpenWorkspaceFile: onOpenWorkspaceFile,
                loadingStatusText: liveLoadingText,
                statsCaption: statsCaption
            )
        }
    }

    private var errorMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(colors.destructive)
            VStack(alignment: .leading, spacing: 4) {
                Text("Something went wrong")
                    .font(AppFont.mono(fontSize, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                Text(message.content)
                    .font(AppFont.sans(fontSize - 1))
                    .foregroundStyle(colors.textSecondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colors.destructive.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(colors.destructive.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Compact, collapsed rendering of an automated tool-results message (run
/// output, edit confirmations, preview errors) — the agent's "terminal"
/// turns, summarized in chat with the full text one click away.
struct ToolResultsCard: View {
    @Environment(\.themeColors) private var colors
    let content: String
    @State private var expanded = false

    private var isPreviewErrors: Bool { content.hasPrefix("[Preview runtime errors") }

    private var summaryItems: [String] {
        if isPreviewErrors {
            return Array(content.components(separatedBy: "\n").dropFirst().prefix(3))
        }
        let lines = content.components(separatedBy: "\n")
        var items: [String] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("### ") {
            var item = String(line.dropFirst(4))
            if index + 1 < lines.count {
                let next = lines[index + 1]
                if next.hasPrefix("exit code:") || next.hasPrefix("OK") || next.hasPrefix("ERROR") {
                    item += "  ·  " + next
                }
            }
            items.append(item)
        }
        return items.isEmpty ? ["results"] : items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isPreviewErrors ? "exclamationmark.triangle" : "terminal")
                        .font(.system(size: 10, weight: .semibold))
                    Text(isPreviewErrors ? "Preview errors" : "Tool results")
                        .font(AppFont.mono(11, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(colors.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(Array(summaryItems.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(AppFont.mono(11))
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
            }

            if expanded {
                ScrollView {
                    Text(content)
                        .font(AppFont.mono(11))
                        .foregroundStyle(colors.textCode)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 240)
                .background(colors.backgroundCode)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colors.backgroundChip.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }
}

/// Assistant body + action row, where the row only appears on hover — it
/// stays reserved-but-invisible (not removed from layout) so hovering
/// doesn't shift the message above/below it.
private struct HoverRevealAssistantBody: View {
    @Environment(\.themeColors) private var colors
    let content: String
    let isActivelyTyping: Bool
    var onRegenerate: () -> Void
    var onOpenWorkspaceFile: ((String) -> Void)? = nil
    /// Real status text for a local model still loading — see
    /// `ThinkingIndicator`.
    var loadingStatusText: String? = nil
    /// A completed message's real generation stats (tokens, speed, and for
    /// a local model: which backend, whether it needed a fresh load, and
    /// its memory footprint) — nil for messages with nothing to show yet.
    var statsCaption: String? = nil
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !content.isEmpty || isActivelyTyping {
                AssistantMessageContentView(
                    text: content,
                    isTyping: isActivelyTyping,
                    onOpenWorkspaceFile: onOpenWorkspaceFile,
                    loadingStatusText: loadingStatusText
                )
            }
            if !isActivelyTyping && !content.isEmpty {
                if let statsCaption {
                    Text(statsCaption)
                        .font(AppFont.mono(11))
                        .foregroundStyle(colors.textTertiary)
                }
                MessageActionsRow(content: content, onRegenerate: onRegenerate)
                    .opacity(isHovered ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Assistant action row

struct MessageActionsRow: View {
    @Environment(\.themeColors) private var colors
    let content: String
    var onRegenerate: () -> Void = {}

    @State private var copied = false
    @State private var reaction: Int = 0 // -1 down, 0 none, 1 up

    var body: some View {
        HStack(spacing: 2) {
            ActionIcon(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            ActionIcon(systemName: reaction == 1 ? "hand.thumbsup.fill" : "hand.thumbsup", help: "Good response") {
                reaction = reaction == 1 ? 0 : 1
            }
            ActionIcon(systemName: reaction == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown", help: "Bad response") {
                reaction = reaction == -1 ? 0 : -1
            }
            ActionIcon(systemName: "arrow.clockwise", help: "Regenerate", action: onRegenerate)
        }
        .padding(.top, 2)
    }
}

private struct ActionIcon: View {
    @Environment(\.themeColors) private var colors
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? colors.backgroundHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
        .help(help)
    }
}
