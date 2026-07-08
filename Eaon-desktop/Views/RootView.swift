import SwiftUI

enum SidebarDestination: Hashable {
    case chat
    case compare
    case feature(AppFeature)
    case project(UUID)
}

enum AppFeature: String, Hashable, CaseIterable {
    case projects = "Projects"
    case models = "Models"

    var icon: String {
        switch self {
        case .projects: return "folder"
        case .models: return "cube"
        }
    }

    var blurb: String {
        switch self {
        case .projects: return "Group related chats and files into projects."
        case .models: return "Download open models and run them on this Mac."
        }
    }
}

struct RootView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var selection: SidebarDestination = .chat
    @State private var sidebarCollapsed = false
    @State private var showingSearchPalette = false
    @State private var showingSettings = false
    @State private var settingsInitialSelectionId: String?
    @State private var conversationPendingDeletion: Conversation?
    @State private var conversationPendingRename: Conversation?
    @State private var showingDeleteAllChats = false
    @State private var showingNewProjectDialog = false
    @State private var projectPendingRename: Project?
    @State private var projectPendingDeletion: Project?
    @State private var showingOnboarding = !KeychainService.hasAPIKey
    @State private var chatViewModel = ChatViewModel()
    @AppStorage("nerd_hud_enabled") private var nerdHUDEnabled = false
    @Bindable private var appearance = AppearanceSettings.shared
    @Bindable private var updateChecker = UpdateChecker.shared

    private var resolvedScheme: ColorScheme {
        appearance.theme.colorScheme ?? systemColorScheme
    }

    private var colors: ThemeColors {
        ThemeColors.forScheme(resolvedScheme)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button("", action: toggleSidebar)
                .keyboardShortcut("\\", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)

            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    SidebarView(
                        viewModel: chatViewModel,
                        selection: $selection,
                        showingSearchPalette: $showingSearchPalette,
                        showingSettings: $showingSettings,
                        onCollapse: { toggleSidebar() },
                        onNewChat: { newChat() },
                        onDeleteRequest: { conversationPendingDeletion = $0 },
                        onRenameRequest: { conversationPendingRename = $0 },
                        onDeleteAllRequest: { showingDeleteAllChats = true },
                        onNewProjectRequest: { showingNewProjectDialog = true },
                        onRenameProjectRequest: { projectPendingRename = $0 },
                        onDeleteProjectRequest: { projectPendingDeletion = $0 }
                    )
                    .frame(width: 240)
                    .floatingSidebarPanel(colors: colors)
                    .transition(.move(edge: .leading))
                }

                detailView
                    .background(colors.backgroundPrimary)
            }
            .background(colors.backgroundPrimary)

            if showingSearchPalette {
                SearchPaletteView(
                    isPresented: $showingSearchPalette,
                    viewModel: chatViewModel,
                    onNewChat: { newChat() },
                    onSelect: { id in
                        chatViewModel.selectConversation(id)
                        selection = .chat
                    },
                    onOpenSettings: { selectionId in
                        settingsInitialSelectionId = selectionId
                        showingSettings = true
                    }
                )
            }

            if showingSettings {
                SettingsRootView(
                    chatViewModel: chatViewModel,
                    isPresented: $showingSettings,
                    initialSelectionId: settingsInitialSelectionId
                )
            }

            if let pending = conversationPendingDeletion {
                DeleteChatDialog(
                    conversation: pending,
                    isPresented: Binding(
                        get: { conversationPendingDeletion != nil },
                        set: { if !$0 { conversationPendingDeletion = nil } }
                    ),
                    onConfirm: {
                        chatViewModel.deleteConversation(pending.id)
                        conversationPendingDeletion = nil
                    }
                )
            }

            if let pending = conversationPendingRename {
                RenameChatDialog(
                    conversation: pending,
                    isPresented: Binding(
                        get: { conversationPendingRename != nil },
                        set: { if !$0 { conversationPendingRename = nil } }
                    ),
                    onConfirm: { newTitle in
                        chatViewModel.renameConversation(pending.id, to: newTitle)
                        conversationPendingRename = nil
                    }
                )
            }

            if showingDeleteAllChats {
                DeleteAllChatsDialog(
                    isPresented: $showingDeleteAllChats,
                    onConfirm: {
                        chatViewModel.deleteAllUnfiledConversations()
                        showingDeleteAllChats = false
                    }
                )
            }

            if showingNewProjectDialog {
                NewProjectDialog(isPresented: $showingNewProjectDialog) { name in
                    let project = chatViewModel.createProject(name: name)
                    selection = .project(project.id)
                }
            }

            if let project = projectPendingRename {
                RenameProjectDialog(
                    project: project,
                    isPresented: Binding(
                        get: { projectPendingRename != nil },
                        set: { if !$0 { projectPendingRename = nil } }
                    ),
                    onConfirm: { newName in
                        chatViewModel.renameProject(project.id, to: newName)
                        projectPendingRename = nil
                    }
                )
            }

            if let project = projectPendingDeletion {
                DeleteProjectDialog(
                    project: project,
                    isPresented: Binding(
                        get: { projectPendingDeletion != nil },
                        set: { if !$0 { projectPendingDeletion = nil } }
                    ),
                    onConfirm: {
                        chatViewModel.deleteProject(project.id)
                        if case .project(let openId) = selection, openId == project.id {
                            selection = .feature(.projects)
                        }
                        projectPendingDeletion = nil
                    }
                )
            }

            if nerdHUDEnabled {
                hudOverlay
            }

            if let manifest = updateChecker.available {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        UpdateBanner(manifest: manifest)
                            .padding(20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(5)
            }

            if showingOnboarding {
                OnboardingView(chatViewModel: chatViewModel) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showingOnboarding = false
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        // Extend content up under the transparent title bar so the sidebar
        // card reaches the very top of the window and the traffic lights sit
        // on top of it (rather than in a reserved strip above the content).
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.themeColors, colors)
        .preferredColorScheme(appearance.colorScheme)
        .tint(appearance.accentColor)
    }

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selection {
            case .chat:
                // The agentic-coding workspace slides in on the right when
                // the model creates files; the chat column itself is
                // untouched, it just shares the width while the panel is up.
                HStack(spacing: 0) {
                    ChatHomeView(
                        viewModel: chatViewModel,
                        isSidebarCollapsed: sidebarCollapsed,
                        onExpandSidebar: { toggleSidebar() },
                        onOpenProviderSettings: { selectionId in
                            settingsInitialSelectionId = selectionId
                            showingSettings = true
                        }
                    )
                    if chatViewModel.isWorkspaceOpen {
                        CodeWorkspacePanel(viewModel: chatViewModel)
                            .frame(width: 440)
                            .floatingWorkspacePanel(colors: colors)
                            .transition(.move(edge: .trailing))
                    }
                }
            case .compare:
                ModelCompareView(availableModels: chatViewModel.aquaOnlyChatModels)
            case .feature(.projects):
                ProjectsView(
                    viewModel: chatViewModel,
                    onOpenProject: { selection = .project($0) },
                    onNewProjectRequest: { showingNewProjectDialog = true },
                    onRenameRequest: { projectPendingRename = $0 },
                    onDeleteRequest: { projectPendingDeletion = $0 }
                )
            case .feature(.models):
                ModelLibraryView(chatViewModel: chatViewModel) { modelId in
                    chatViewModel.startNewChat()
                    chatViewModel.selectModel(modelId)
                    selection = .chat
                }
            case .project(let id):
                if let project = chatViewModel.projects.first(where: { $0.id == id }) {
                    ProjectDetailScreen(
                        viewModel: chatViewModel,
                        project: project,
                        onBack: { selection = .feature(.projects) },
                        onOpenChat: { selection = .chat },
                        onRenameRequest: { projectPendingRename = $0 },
                        onDeleteRequest: { projectPendingDeletion = $0 }
                    )
                } else {
                    // Deleted from elsewhere (e.g. context menu while it was
                    // open) — fall back to the projects list rather than a
                    // dead detail screen for a folder that no longer exists.
                    ProjectsView(
                        viewModel: chatViewModel,
                        onOpenProject: { selection = .project($0) },
                        onNewProjectRequest: { showingNewProjectDialog = true },
                        onRenameRequest: { projectPendingRename = $0 },
                        onDeleteRequest: { projectPendingDeletion = $0 }
                    )
                }
            case .feature(let feature):
                FeaturePlaceholderView(feature: feature)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleSidebar() {
        withAnimation(.linear(duration: 0.2)) {
            sidebarCollapsed.toggle()
        }
    }

    private func newChat() {
        chatViewModel.startNewChat()
        selection = .chat
    }

    private var hudOverlay: some View {
        let pos = appearance.notificationPosition
        return VStack {
            if pos == .bottomRight || pos == .bottomLeft { Spacer() }
            HStack {
                if pos == .topRight || pos == .bottomRight { Spacer() }
                StatisticsHUDView(chatViewModel: chatViewModel)
                    .padding(12)
                if pos == .topLeft || pos == .bottomLeft { Spacer() }
            }
            if pos == .topRight || pos == .topLeft { Spacer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private extension View {
    /// The sidebar's floating-card treatment — inset on all sides with a
    /// flat hairline and a restrained shadow, so it reads as a raised panel
    /// without the gloss of a gradient sheen or a heavy multi-layer shadow.
    /// 16px matches the radius already used for the app's other large panels
    /// (Settings, Search) — smaller confirmation dialogs go a bit rounder
    /// (20px) since a big panel needs a proportionally tighter curve to
    /// avoid looking like a rounded blob. A small, even inset on every side
    /// (including the top) lets the rounded corners breathe against the
    /// window edge rather than getting clipped by it; the traffic lights are
    /// nudged inward (see WindowChrome) so they still land on the card.
    func floatingSidebarPanel(colors: ThemeColors) -> some View {
        self
            .background(colors.backgroundSidebar)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
            .padding(.top, 10)
            .padding(.bottom, 9)
            .padding(.leading, 9)
            .padding(.trailing, 6)
    }

    /// The workspace panel's mirror-image of the sidebar card, so the window
    /// reads as chat flanked by two matching floating panels.
    func floatingWorkspacePanel(colors: ThemeColors) -> some View {
        self
            .background(colors.backgroundSidebar)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
            .padding(.top, 10)
            .padding(.bottom, 9)
            .padding(.leading, 3)
            .padding(.trailing, 9)
    }
}
