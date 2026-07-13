import SwiftUI

enum SidebarDestination: Hashable {
    /// One of the four top-level modes (Chat / Agent / Eaon Claw / Image
    /// Studio) — the conversational surface, framed for that mode.
    case mode(EaonMode)
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
    @State private var selection: SidebarDestination = .mode(.chat)
    /// One-shot so the app reopens on the mode it was last left in (the
    /// viewModel restores `currentMode` from defaults) without re-forcing
    /// that mode every time this view reappears — e.g. returning from
    /// Projects or Settings must not yank you back to a mode surface.
    @State private var didInitialModeSync = false
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
                        chatViewModel.enterMode(.chat)
                        selection = .mode(.chat)
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

            if let path = chatViewModel.pendingRunConfirmation {
                RunConfirmationDialog(
                    path: path,
                    onAllow: { chatViewModel.respondToRunConfirmation(allow: true) },
                    onDeny: { chatViewModel.respondToRunConfirmation(allow: false) }
                )
                .zIndex(20)
            }

            if let call = chatViewModel.pendingMCPCallConfirmation {
                MCPCallConfirmationDialog(
                    call: call,
                    onAllow: { chatViewModel.respondToMCPCallConfirmation(allow: true) },
                    onDeny: { chatViewModel.respondToMCPCallConfirmation(allow: false) }
                )
                .zIndex(20)
            }

            if let call = chatViewModel.pendingDesktopCallConfirmation {
                DesktopCallConfirmationDialog(
                    call: call,
                    onAllowOnce: { chatViewModel.respondToDesktopCallConfirmation(.allowOnce) },
                    onAllowAll: { chatViewModel.respondToDesktopCallConfirmation(.allowAll) },
                    onDeny: { chatViewModel.respondToDesktopCallConfirmation(.deny) }
                )
                .zIndex(20)
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

        }
        // Extend content up under the transparent title bar so the sidebar
        // card reaches the very top of the window and the traffic lights sit
        // on top of it (rather than in a reserved strip above the content).
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.themeColors, colors)
        .preferredColorScheme(appearance.colorScheme)
        .tint(appearance.accentColor)
        .onAppear {
            guard !didInitialModeSync else { return }
            didInitialModeSync = true
            selection = .mode(chatViewModel.currentMode)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selection {
            case .mode(.chat), .mode(.agent):
                // Chat and the sandboxed coding Agent share the conversational
                // surface; the coding workspace slides in on the right when
                // the model creates files (most relevant in Agent mode).
                let mode: EaonMode = { if case .mode(let m) = selection { return m } else { return .chat } }()
                HStack(spacing: 0) {
                    ChatHomeView(
                        viewModel: chatViewModel,
                        isSidebarCollapsed: sidebarCollapsed,
                        onExpandSidebar: { toggleSidebar() },
                        onOpenProviderSettings: { selectionId in
                            settingsInitialSelectionId = selectionId
                            showingSettings = true
                        },
                        mode: mode,
                        onModeChange: switchMode
                    )
                    if chatViewModel.isWorkspaceOpen {
                        CodeWorkspacePanel(viewModel: chatViewModel)
                            .frame(width: 440)
                            .floatingWorkspacePanel(colors: colors)
                            .transition(.move(edge: .trailing))
                    }
                }
            case .mode(.claw):
                ClawHomeView(
                    viewModel: chatViewModel,
                    isSidebarCollapsed: sidebarCollapsed,
                    onExpandSidebar: { toggleSidebar() },
                    onOpenProviderSettings: { selectionId in
                        settingsInitialSelectionId = selectionId
                        showingSettings = true
                    },
                    onModeChange: switchMode
                )
            case .mode(.imageStudio):
                ImageStudioHomeView(
                    viewModel: chatViewModel,
                    isSidebarCollapsed: sidebarCollapsed,
                    onExpandSidebar: { toggleSidebar() },
                    onOpenProviderSettings: { selectionId in
                        settingsInitialSelectionId = selectionId
                        showingSettings = true
                    },
                    onModeChange: switchMode
                )
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
                    chatViewModel.enterMode(.chat)
                    selection = .mode(.chat)
                }
            case .project(let id):
                if let project = chatViewModel.projects.first(where: { $0.id == id }) {
                    ProjectDetailScreen(
                        viewModel: chatViewModel,
                        project: project,
                        onBack: { selection = .feature(.projects) },
                        onOpenChat: { chatViewModel.enterMode(.chat); selection = .mode(.chat) },
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
        // Keep whatever mode the user is in — a new chat inside Eaon Claw
        // should stay Eaon Claw, not drop back to plain Chat.
        selection = .mode(chatViewModel.currentMode)
    }

    /// The mode switcher (composer bar, plus the Eaon Claw/Image Studio
    /// gate screens) only has a view onto `viewModel.currentMode` — it can't
    /// see `selection`, which is what actually decides which top-level view
    /// this window shows. This is the one place that keeps both in sync.
    private func switchMode(_ mode: EaonMode) {
        selection = .mode(mode)
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
