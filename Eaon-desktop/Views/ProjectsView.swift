import SwiftUI

/// The "Projects" list destination — plain folders for grouping chats. No
/// per-project assistant, instructions, or knowledge base: a project here is
/// just a name you can file chats into, rename, or delete. All project
/// dialogs (new/rename/delete) are hosted centrally by RootView, same as
/// conversations — this view just triggers them via callbacks.
struct ProjectsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var viewModel: ChatViewModel
    var onOpenProject: (UUID) -> Void = { _ in }
    var onNewProjectRequest: () -> Void = {}
    var onRenameRequest: (Project) -> Void = { _ in }
    var onDeleteRequest: (Project) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(colors.borderSubtle)

            if viewModel.sortedProjects.isEmpty {
                emptyState
            } else {
                projectGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.backgroundPrimary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Projects")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(colors.textPrimary)

            Spacer(minLength: 0)

            Button(action: onNewProjectRequest) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New project")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().stroke(colors.borderMedium, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(colors.backgroundSubtle)
                    .frame(width: 72, height: 72)
                Image(systemName: "folder")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(colors.textSecondary)
            }

            Text("Projects")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(colors.textPrimary)

            Text("Group related chats into a folder.")
                .font(.system(size: 14))
                .foregroundStyle(colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button(action: onNewProjectRequest) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New project")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(colors.backgroundPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(colors.textPrimary))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 4)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Project grid

    private var projectGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 12)], spacing: 12) {
                ForEach(viewModel.sortedProjects) { project in
                    ProjectFolderCard(
                        project: project,
                        chatCount: viewModel.conversations(inProject: project.id).count,
                        onOpen: { onOpenProject(project.id) },
                        onRename: { onRenameRequest(project) },
                        onDelete: { onDeleteRequest(project) }
                    )
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Folder card

private struct ProjectFolderCard: View {
    @Environment(\.themeColors) private var colors
    let project: Project
    let chatCount: Int
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(colors.textSecondary)

                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)

                Text(chatCount == 1 ? "1 chat" : "\(chatCount) chats")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? colors.backgroundHover : colors.backgroundSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

// MARK: - Project detail screen (opened from the sidebar or the grid)

/// Shows one project's chats — reached either by clicking its sidebar row
/// directly or by opening its card from the `ProjectsView` grid. Both paths
/// land here through `SidebarDestination.project(_:)`, so there's a single
/// place that owns this layout.
struct ProjectDetailScreen: View {
    @Environment(\.themeColors) private var colors
    @Bindable var viewModel: ChatViewModel
    let project: Project
    var onBack: () -> Void = {}
    var onOpenChat: () -> Void = {}
    var onRenameRequest: (Project) -> Void = { _ in }
    var onDeleteRequest: (Project) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(colors.borderSubtle)
            ProjectDetailContent(viewModel: viewModel, project: project, onOpenChat: onOpenChat)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.backgroundPrimary)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())

            Text(project.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Menu {
                Button { onRenameRequest(project) } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { onDeleteRequest(project) } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }
}

private struct ProjectDetailContent: View {
    @Environment(\.themeColors) private var colors
    @Bindable var viewModel: ChatViewModel
    let project: Project
    var onOpenChat: () -> Void

    private var chats: [Conversation] {
        viewModel.conversations(inProject: project.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                newChatRow

                if !chats.isEmpty {
                    ForEach(chats) { conversation in
                        ProjectChatRow(
                            conversation: conversation,
                            isActive: viewModel.currentConversationId == conversation.id,
                            onSelect: {
                                viewModel.selectConversation(conversation.id)
                                onOpenChat()
                            }
                        )
                    }
                } else {
                    Text("No chats in this project yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                }
            }
            .padding(16)
        }
    }

    private var newChatRow: some View {
        Button {
            viewModel.startNewChat(inProject: project.id)
            onOpenChat()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                Text("New chat in \(project.name)")
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(colors.backgroundSubtle)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .padding(.bottom, 8)
    }
}

private struct ProjectChatRow: View {
    @Environment(\.themeColors) private var colors
    let conversation: Conversation
    let isActive: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "message")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
                Text(conversation.title)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? colors.backgroundSelected : (isHovered ? colors.backgroundHover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
    }
}
