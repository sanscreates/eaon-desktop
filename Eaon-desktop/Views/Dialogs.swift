import AppKit
import SwiftUI

// MARK: - Delete chat dialog

struct DeleteChatDialog: View {
    @Environment(\.themeColors) private var colors
    let conversation: Conversation
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            colors.backgroundOverlay
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("Delete chat?")
                    .font(AppFont.mono(18, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 14)

                (Text("This will delete ")
                    .foregroundStyle(colors.textSecondary)
                 + Text(conversation.title)
                    .foregroundStyle(colors.textPrimary)
                    .fontWeight(.semibold)
                 + Text(".")
                    .foregroundStyle(colors.textSecondary))
                    .font(AppFont.sans(14))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)

                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", style: .secondary) { dismiss() }
                    DialogButton(title: "Delete", style: .destructive) {
                        onConfirm()
                    }
                }
            }
            .padding(24)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colors.backgroundPopover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - Delete all chats dialog

struct DeleteAllChatsDialog: View {
    @Environment(\.themeColors) private var colors
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            colors.backgroundOverlay
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("Delete all chats?")
                    .font(AppFont.mono(18, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 14)

                Text("Chats not filed in a project will be deleted. This action cannot be undone.")
                    .font(AppFont.sans(14))
                    .foregroundStyle(colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)

                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", style: .secondary) { dismiss() }
                    DialogButton(title: "Delete All", style: .destructive) {
                        onConfirm()
                    }
                }
            }
            .padding(24)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colors.backgroundPopover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

enum DialogButtonStyle { case primary, secondary, destructive }

struct DialogButton: View {
    @Environment(\.themeColors) private var colors
    let title: String
    var style: DialogButtonStyle = .secondary
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.mono(14, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(
                    Capsule().fill(background)
                )
                .overlay(
                    Capsule().stroke(style == .secondary ? colors.borderMedium : .clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: return colors.backgroundPrimary
        case .secondary: return colors.textPrimary
        case .destructive: return .white
        }
    }

    private var background: Color {
        switch style {
        case .primary: return colors.textPrimary
        case .secondary: return isHovered ? colors.backgroundHover : .clear
        case .destructive: return colors.destructive.opacity(isHovered ? 0.9 : 1)
        }
    }
}

/// A filled, accent-colored action button. Replaces `.buttonStyle(.borderedProminent)`,
/// which assumes white label text works on any tint — that assumption breaks
/// the moment the user's accent color is white.
struct AccentButton: View {
    let title: String
    var isDisabled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.mono(13, weight: .semibold))
                .foregroundStyle(AppearanceSettings.shared.onAccentColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(AppearanceSettings.shared.accentColor.opacity(isHovered ? 0.9 : 1))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.5 : 1)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Rename chat dialog

struct RenameChatDialog: View {
    @Environment(\.themeColors) private var colors
    let conversation: Conversation
    @Binding var isPresented: Bool
    let onConfirm: (String) -> Void

    @State private var title: String
    @State private var appeared = false
    @FocusState private var isFocused: Bool

    init(conversation: Conversation, isPresented: Binding<Bool>, onConfirm: @escaping (String) -> Void) {
        self.conversation = conversation
        self._isPresented = isPresented
        self.onConfirm = onConfirm
        self._title = State(initialValue: conversation.title)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !trimmedTitle.isEmpty && trimmedTitle != conversation.title
    }

    var body: some View {
        ZStack {
            colors.backgroundOverlay
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("Rename chat")
                    .font(AppFont.mono(18, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 14)

                TextField("Chat title", text: $title)
                    .textFieldStyle(.plain)
                    .font(AppFont.mono(14))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(colors.backgroundInputSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(colors.borderMedium, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .padding(.bottom, 24)

                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", style: .secondary) { dismiss() }
                    DialogButton(title: "Rename", style: .primary) { commit() }
                        .disabled(!canRename)
                        .opacity(canRename ? 1 : 0.5)
                }
            }
            .padding(24)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colors.backgroundPopover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isFocused = true }
        }
        .onExitCommand { dismiss() }
    }

    private func commit() {
        guard canRename else { return }
        onConfirm(trimmedTitle)
        isPresented = false
    }

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - New project dialog

/// Create-folder flow — a name, nothing else. Deliberately no
/// assistant/instructions/knowledge-base step: Aqua projects are plain
/// folders for grouping chats.
struct NewProjectDialog: View {
    @Environment(\.themeColors) private var colors
    @Binding var isPresented: Bool
    let onConfirm: (String) -> Void

    @State private var name: String = ""
    @State private var appeared = false
    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool { !trimmedName.isEmpty }

    var body: some View {
        ZStack {
            colors.backgroundOverlay
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("New project")
                    .font(AppFont.mono(18, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 14)

                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(AppFont.mono(14))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(colors.backgroundInputSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(colors.borderMedium, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .padding(.bottom, 24)

                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", style: .secondary) { dismiss() }
                    DialogButton(title: "Create", style: .primary) { commit() }
                        .disabled(!canCreate)
                        .opacity(canCreate ? 1 : 0.5)
                }
            }
            .padding(24)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colors.backgroundPopover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isFocused = true }
        }
        .onExitCommand { dismiss() }
    }

    private func commit() {
        guard canCreate else { return }
        onConfirm(trimmedName)
        isPresented = false
    }

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - Rename project dialog

struct RenameProjectDialog: View {
    @Environment(\.themeColors) private var colors
    let project: Project
    @Binding var isPresented: Bool
    let onConfirm: (String) -> Void

    @State private var name: String
    @State private var appeared = false
    @FocusState private var isFocused: Bool

    init(project: Project, isPresented: Binding<Bool>, onConfirm: @escaping (String) -> Void) {
        self.project = project
        self._isPresented = isPresented
        self.onConfirm = onConfirm
        self._name = State(initialValue: project.name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !trimmedName.isEmpty && trimmedName != project.name
    }

    var body: some View {
        ZStack {
            colors.backgroundOverlay
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("Rename project")
                    .font(AppFont.mono(18, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 14)

                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(AppFont.mono(14))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(colors.backgroundInputSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(colors.borderMedium, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .padding(.bottom, 24)

                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", style: .secondary) { dismiss() }
                    DialogButton(title: "Rename", style: .primary) { commit() }
                        .disabled(!canRename)
                        .opacity(canRename ? 1 : 0.5)
                }
            }
            .padding(24)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colors.backgroundPopover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isFocused = true }
        }
        .onExitCommand { dismiss() }
    }

    private func commit() {
        guard canRename else { return }
        onConfirm(trimmedName)
        isPresented = false
    }

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - Delete project dialog

struct DeleteProjectDialog: View {
    @Environment(\.themeColors) private var colors
    let project: Project
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            colors.backgroundOverlay
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("Delete project?")
                    .font(AppFont.mono(18, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.bottom, 14)

                (Text("This deletes the ")
                    .foregroundStyle(colors.textSecondary)
                 + Text(project.name)
                    .foregroundStyle(colors.textPrimary)
                    .fontWeight(.semibold)
                 + Text(" folder. Its chats stay in your chat list.")
                    .foregroundStyle(colors.textSecondary))
                    .font(AppFont.sans(14))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)

                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", style: .secondary) { dismiss() }
                    DialogButton(title: "Delete", style: .destructive) {
                        onConfirm()
                    }
                }
            }
            .padding(24)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colors.backgroundPopover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - Share chat sheet

struct ShareChatSheet: View {
    @Environment(\.themeColors) private var colors
    let conversation: Conversation
    @Binding var isPresented: Bool

    @State private var appeared = false
    @State private var copied = false

    private var firstUserPrompt: String {
        conversation.messages.first { $0.isUser }?.content ?? conversation.title
    }

    var body: some View {
        ZStack {
            colors.backgroundOverlay
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(conversation.title)
                        .font(AppFont.mono(20, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(colors.textSecondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(.bottom, 16)

                Divider().overlay(colors.borderSubtle).padding(.bottom, 18)

                previewCard.padding(.bottom, 22)

                HStack(spacing: 22) {
                    ShareTarget(icon: copied ? "checkmark" : "link", label: copied ? "Copied" : "Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("https://aquadevs.com/share/\(conversation.id.uuidString.prefix(8).lowercased())", forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    ShareTarget(icon: "bird", label: "X") {}
                    ShareTarget(icon: "briefcase", label: "LinkedIn") {}
                    ShareTarget(icon: "bubble.left.and.bubble.right", label: "Reddit") {}
                    Spacer()
                }
                .padding(.bottom, 18)

                Divider().overlay(colors.borderSubtle).padding(.bottom, 18)

                HStack(spacing: 22) {
                    ShareTarget(icon: "doc.plaintext", label: "Export Markdown") {
                        exportToFile(
                            content: ChatViewModel.exportConversationMarkdown(conversation),
                            suggestedName: "\(conversation.title).md"
                        )
                    }
                    ShareTarget(icon: "curlybraces", label: "Export JSON") {
                        guard let data = ChatViewModel.exportConversationJSON(conversation) else { return }
                        exportToFile(data: data, suggestedName: "\(conversation.title).json")
                    }
                    Spacer()
                }
            }
            .padding(24)
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(colors.backgroundPopover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 44, y: 18)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.18)) { appeared = true } }
    }

    private func exportToFile(content: String, suggestedName: String) {
        exportToFile(data: Data(content.utf8), suggestedName: suggestedName)
    }

    private func exportToFile(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private var previewCard: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack {
                Spacer(minLength: 40)
                Text(firstUserPrompt)
                    .font(AppFont.sans(13))
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(colors.userBubble)
                    )
            }
            HStack {
                AquaMark(size: 22)
                AquaWordmark(size: 14)
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colors.backgroundPrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }
}

private struct ShareTarget: View {
    @Environment(\.themeColors) private var colors
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(colors.backgroundPrimary)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(colors.textPrimary.opacity(isHovered ? 0.85 : 1)))
                Text(label)
                    .font(AppFont.mono(12))
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
    }
}
