import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var viewModel: ChatViewModel
    @Binding var selection: SidebarDestination
    @Binding var showingSearchPalette: Bool
    @Binding var showingSettings: Bool
    var onCollapse: () -> Void = {}
    var onNewChat: () -> Void = {}
    var onDeleteRequest: (Conversation) -> Void = { _ in }
    var onRenameRequest: (Conversation) -> Void = { _ in }
    var onDeleteAllRequest: () -> Void = {}
    var onNewProjectRequest: () -> Void = {}
    var onRenameProjectRequest: (Project) -> Void = { _ in }
    var onDeleteProjectRequest: (Project) -> Void = { _ in }

    /// Which project folders are expanded inline in the sidebar — a folder's
    /// chats only ever show here, on click, never mixed into the flat
    /// "Chats" list below.
    @State private var expandedProjectIds: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    navItems
                    pinnedSection
                    projectsSection
                    chatHistory
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    /// A title-bar band tall enough for the native traffic-light window
    /// controls to sit inside it on the left; only the collapse toggle lives
    /// here, on the right, so it never collides with them.
    private var header: some View {
        HStack(spacing: 2) {
            Spacer()
            SidebarIconButton(systemName: "sidebar.left", help: "Close sidebar", action: onCollapse)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
    }

    // MARK: - Nav items

    private var navItems: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarNavRow(icon: "square.and.pencil", title: "New Chat", trailing: "⌘N", shortcut: "n") {
                onNewChat()
            }
            SidebarNavRow(
                icon: "folder.badge.plus",
                title: "New Projects",
                trailing: "⌘P",
                isActive: selection == .feature(.projects),
                shortcut: "p"
            ) {
                selection = .feature(.projects)
            }
            SidebarNavRow(icon: "magnifyingglass", title: "Search", trailing: "⌘K", shortcut: "k") {
                showingSearchPalette = true
            }
            SidebarNavRow(
                icon: "cube",
                title: "Models",
                isActive: selection == .feature(.models)
            ) {
                selection = .feature(.models)
            }
            SidebarNavRow(icon: "gearshape", title: "Settings") {
                showingSettings = true
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Projects

    /// Only shown once at least one project exists — with none yet, "New
    /// Projects" above already leads to the empty state's own creation CTA,
    /// so an empty "Projects" header here would just be clutter.
    @ViewBuilder
    private var projectsSection: some View {
        let items = viewModel.sortedProjects
        if !items.isEmpty {
            HStack(spacing: 4) {
                Text("Projects")
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundStyle(colors.textTertiary)

                Spacer(minLength: 0)

                Button(action: onNewProjectRequest) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New project")
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(items) { project in
                let isExpanded = expandedProjectIds.contains(project.id)

                ProjectRow(
                    project: project,
                    isExpanded: isExpanded,
                    onToggle: { toggleExpanded(project.id) },
                    onRename: { onRenameProjectRequest(project) },
                    onDelete: { onDeleteProjectRequest(project) }
                )

                if isExpanded {
                    let chats = viewModel.conversations(inProject: project.id)
                    if chats.isEmpty {
                        Text("No chats yet")
                            .font(AppFont.mono(12))
                            .foregroundStyle(colors.textTertiary)
                            .padding(.leading, 38)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(chats) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isActive: viewModel.currentConversationId == conversation.id,
                                onSelect: {
                                    viewModel.selectConversation(conversation.id)
                                    selection = .chat
                                },
                                onRename: { onRenameRequest(conversation) },
                                onDelete: { onDeleteRequest(conversation) },
                                showsPinOption: false
                            )
                            .padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }

    private func toggleExpanded(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expandedProjectIds.contains(id) {
                expandedProjectIds.remove(id)
            } else {
                expandedProjectIds.insert(id)
            }
        }
    }

    // MARK: - Pinned

    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = viewModel.pinnedConversations
        if !pinned.isEmpty {
            HStack(spacing: 4) {
                Text("Pinned")
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundStyle(colors.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(pinned) { conversation in
                ConversationRow(
                    conversation: conversation,
                    isActive: viewModel.currentConversationId == conversation.id,
                    onSelect: {
                        viewModel.selectConversation(conversation.id)
                        selection = .chat
                    },
                    onRename: { onRenameRequest(conversation) },
                    onDelete: { onDeleteRequest(conversation) },
                    onTogglePin: { viewModel.togglePinned(conversation.id) }
                )
            }
        }
    }

    // MARK: - Chat history

    @ViewBuilder
    private var chatHistory: some View {
        let unfiled = viewModel.unpinnedUnfiledConversations
        let buckets = Self.dateBuckets(for: unfiled)
        if !buckets.isEmpty {
            ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                HStack(spacing: 4) {
                    Text(bucket.title)
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundStyle(colors.textTertiary)

                    Spacer(minLength: 0)

                    if index == 0 && unfiled.count > 1 {
                        Menu {
                            Button(role: .destructive) {
                                onDeleteAllRequest()
                            } label: {
                                Label("Delete All", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(colors.textTertiary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, index == 0 ? 12 : 16)
                .padding(.bottom, 4)

                ForEach(bucket.conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        isActive: viewModel.currentConversationId == conversation.id,
                        onSelect: {
                            viewModel.selectConversation(conversation.id)
                            selection = .chat
                        },
                        onRename: { onRenameRequest(conversation) },
                        onDelete: { onDeleteRequest(conversation) },
                        onTogglePin: { viewModel.togglePinned(conversation.id) }
                    )
                }
            }
        }
    }

    /// Groups already most-recent-first conversations into ChatGPT's date
    /// buckets (Today / Yesterday / Previous 7 Days / Previous 30 Days / by
    /// month) without re-sorting — the incoming order already determines
    /// bucket order, so this is a single linear pass.
    private struct ConversationBucket {
        let title: String
        var conversations: [Conversation]
    }

    private static func dateBuckets(for conversations: [Conversation]) -> [ConversationBucket] {
        var buckets: [ConversationBucket] = []
        for conversation in conversations {
            let title = bucketTitle(for: conversation.updatedAt)
            if buckets.last?.title == title {
                buckets[buckets.count - 1].conversations.append(conversation)
            } else {
                buckets.append(ConversationBucket(title: title, conversations: [conversation]))
            }
        }
        return buckets
    }

    private static func bucketTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0

        if days < 7 { return "Previous 7 Days" }
        if days < 30 { return "Previous 30 Days" }

        let formatter = DateFormatter()
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        formatter.dateFormat = sameYear ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Account row

}

// MARK: - Aqua brand mark

/// A peak rising from a wave — reads as both "A" and water, echoing the
/// swell photography and angular wordmark on aquadevs.com. Deliberately
/// simple: at the 18–30px sizes this renders in, fine letterform detail
/// (e.g. a literal crossbar) would just turn to mud.
struct AquaGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.5, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.86, y: h * 0.80))
        path.addCurve(
            to: CGPoint(x: w * 0.14, y: h * 0.80),
            control1: CGPoint(x: w * 0.68, y: h * 0.62),
            control2: CGPoint(x: w * 0.32, y: h * 0.62)
        )
        path.closeSubpath()
        return path
    }
}

struct AquaMark: View {
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(AquaBrand.accent)
            AquaGlyph()
                .fill(.white)
                .frame(width: size * 0.52, height: size * 0.52)
                .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

/// The app's own wordmark — "Eaon," the product name. Distinct from "Aqua
/// Devs," the company/backend brand (Aqua API, aquadevs.com), which is
/// unchanged — same relationship as "ChatGPT" the product vs "OpenAI" the
/// company.
struct AquaWordmark: View {
    var size: CGFloat = 16
    @Environment(\.themeColors) private var colors

    var body: some View {
        Text("Eaon")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(colors.textPrimary)
    }
}

// MARK: - Nav row

private struct SidebarNavRow: View {
    @Environment(\.themeColors) private var colors
    let icon: String
    let title: String
    var trailing: String? = nil
    var isActive: Bool = false
    var shortcut: KeyEquivalent? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(colors.textPrimary.opacity(0.85))
                    .frame(width: 20)
                Text(title)
                    .font(AppFont.mono(14, weight: .regular))
                    .foregroundStyle(colors.textPrimary)
                Spacer(minLength: 0)
                if let trailing {
                    ShortcutHintView(shortcut: trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? colors.backgroundSelected : (isHovered ? colors.backgroundHover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .modifier(OptionalShortcut(shortcut: shortcut))
        .onHover { isHovered = $0 }
    }
}

/// Renders a shortcut like "⌘N" as separated, muted glyphs (⌘  N), always
/// visible — matching the target layout's persistent key hints.
private struct ShortcutHintView: View {
    @Environment(\.themeColors) private var colors
    let shortcut: String

    private var glyphs: [String] {
        guard let key = shortcut.last else { return [] }
        let modifiers = String(shortcut.dropLast())
        return [modifiers, String(key)].filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                Text(glyph)
                    .font(AppFont.mono(12, weight: .regular))
                    .foregroundStyle(colors.textTertiary)
            }
        }
    }
}

private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyEquivalent?
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Conversation row

private struct ConversationRow: View {
    @Environment(\.themeColors) private var colors
    let conversation: Conversation
    let isActive: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    var onTogglePin: () -> Void = {}
    /// Pinning only means anything for an unfiled chat — the Pinned
    /// section lives alongside the flat "Chats" list, not inside a
    /// project's own disclosure, so a project chat's row omits the option
    /// entirely rather than offering a toggle with no visible effect.
    var showsPinOption: Bool = true

    @State private var isHovered = false

    private var isPinned: Bool { conversation.isPinned == true }
    private var pinLabel: String { isPinned ? "Unpin" : "Pin" }
    private var pinIcon: String { isPinned ? "pin.slash" : "pin" }

    var body: some View {
        Button(action: onSelect) { rowContent }
            .buttonStyle(PressableButtonStyle())
            .onHover { isHovered = $0 }
            .contextMenu {
                if showsPinOption {
                    Button { onTogglePin() } label: { Label(pinLabel, systemImage: pinIcon) }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private var rowContent: some View {
        // The trailing slot is ALWAYS in the layout (the menu just fades in)
        // and never taller than the text line — so hovering can't change the
        // row's height or the title's width, and nothing below shifts.
        HStack(spacing: 8) {
            Text(conversation.title)
                .font(AppFont.mono(14))
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            ZStack {
                if conversation.hasUnread {
                    Circle()
                        .fill(colors.textPrimary)
                        .frame(width: 7, height: 7)
                        .opacity(isHovered || isActive ? 0 : 1)
                }
                Menu {
                    if showsPinOption {
                        Button { onTogglePin() } label: { Label(pinLabel, systemImage: pinIcon) }
                    }
                    Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 22, height: 17)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .opacity(isHovered || isActive ? 1 : 0)
                .allowsHitTesting(isHovered || isActive)
            }
            .frame(width: 22, height: 17)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? colors.backgroundSelected : (isHovered ? colors.backgroundHover : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Project row

/// A disclosure row — clicking it only expands/collapses its chats inline,
/// it never navigates away. Chats inside are the *only* place they're shown
/// in the sidebar; they're deliberately excluded from the flat "Chats" list.
private struct ProjectRow: View {
    @Environment(\.themeColors) private var colors
    let project: Project
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) { rowContent }
            .buttonStyle(PressableButtonStyle())
            .onHover { isHovered = $0 }
            .contextMenu {
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)

            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(colors.textSecondary)
                .frame(width: 16)

            Text(project.name)
                .font(AppFont.mono(14))
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Always-reserved slot, same reasoning as ConversationRow: the
            // hover menu fades in without ever changing the row's geometry.
            Menu {
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: 22, height: 17)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isExpanded ? colors.backgroundSelected : (isHovered ? colors.backgroundHover : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }
}

// MARK: - Shared components

struct SidebarIconButton: View {
    @Environment(\.themeColors) private var colors
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(colors.textSecondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? colors.backgroundHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Subtle scale-on-press feedback (Emil: buttons must feel responsive).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.uiEaseOut(duration: 0.12), value: configuration.isPressed)
    }
}
