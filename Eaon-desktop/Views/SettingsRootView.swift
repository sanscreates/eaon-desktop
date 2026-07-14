import SwiftUI

private struct SettingsCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    /// Shows a small "BETA" pill next to this category in the sidebar —
    /// for a feature real enough to ship but new enough that "still
    /// stabilizing" is honest to say up front, not just implied.
    var isBeta: Bool = false
}

/// Presented as a centered floating card over a dimmed backdrop — matching
/// the target, where Settings is a modal window rather than a navigation
/// destination that replaces the whole chat view.
struct SettingsRootView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var chatViewModel: ChatViewModel
    @Bindable private var modelPrefs = ModelPreferencesStore.shared
    @Bindable private var customStore = CustomProviderStore.shared
    @Bindable private var localManager = LocalAIManager.shared
    @Binding var isPresented: Bool
    @State private var selectedId: String
    @State private var appeared = false
    @State private var isAddingProvider = false

    /// `initialSelectionId` lets a caller outside this view's own sidebar —
    /// e.g. the gear icon on a provider's group in the model picker — open
    /// Settings landed directly on that provider's page, instead of always
    /// starting on General.
    init(chatViewModel: ChatViewModel, isPresented: Binding<Bool>, initialSelectionId: String? = nil) {
        self.chatViewModel = chatViewModel
        self._isPresented = isPresented
        self._selectedId = State(initialValue: initialSelectionId ?? "general")
    }

    private let mainCategories: [SettingsCategory] = [
        .init(id: "general",      title: "General",              icon: "gearshape"),
        .init(id: "instructions", title: "Custom Instructions",  icon: "text.quote"),
        .init(id: "memory",       title: "Memory",                icon: "brain"),
        .init(id: "plugins",      title: "Plugins",                icon: "puzzlepiece.extension"),
        .init(id: "skills",       title: "Skills",                 icon: "bolt.fill", isBeta: true),
        .init(id: "imageProviders", title: "Image Providers",     icon: "photo"),
        .init(id: "computer",     title: "Computer Control",       icon: "desktopcomputer", isBeta: true),
        .init(id: "localServer",  title: "Local API Server",      icon: "server.rack", isBeta: true),
        .init(id: "appearance",   title: "Appearance",           icon: "paintpalette"),
        .init(id: "shortcuts",    title: "Shortcuts",             icon: "keyboard"),
        .init(id: "privacy",      title: "Privacy",               icon: "lock.fill"),
        .init(id: "statistics",   title: "Statistics",            icon: "chart.bar"),
        .init(id: "hardware",     title: "Hardware",              icon: "cpu"),
    ]

    private let providerCategories: [SettingsCategory] = [
        .init(id: "aqua", title: "Aqua API", icon: "drop.fill"),
    ]

    private func customProviderSelectionId(_ config: CustomProviderConfig) -> String {
        "custom-provider:\(config.id.uuidString)"
    }

    private func config(for selectedId: String) -> CustomProviderConfig? {
        guard selectedId.hasPrefix("custom-provider:") else { return nil }
        let idString = String(selectedId.dropFirst("custom-provider:".count))
        return customStore.configs.first { $0.id.uuidString == idString }
    }

    // Named rather than inline closures below — a multi-statement inline
    // closure with two named arguments here previously tipped the whole
    // (already large) `body` expression over SwiftUI's type-checker
    // timeout, an unrelated-looking compile error dozens of lines away.
    private func finishAddingProvider() {
        isAddingProvider = false
    }

    private func switchToAquaFromAddProvider() {
        isAddingProvider = false
        selectedId = "aqua"
    }

    var body: some View {
        ZStack {
            colors.backgroundOverlay
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            card
                .scaleEffect(appeared ? 1 : 0.96)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.16)) { appeared = true }
        }
        .onExitCommand { isPresented = false }
    }

    private var card: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(AppFont.mono(20, weight: .bold))
                    .foregroundColor(colors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                // The provider brand list can run well past the card's fixed
                // height (every Aqua-served + BYOK brand gets its own row),
                // so the nav itself has to scroll — only the title above
                // stays put.
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(mainCategories) { cat in
                            SettingsSidebarRow(category: cat, isSelected: selectedId == cat.id)
                                .onTapGesture { selectedId = cat.id }
                        }
                    }
                    .padding(.horizontal, 8)

                    modelProvidersSection
                }
            }
            .frame(width: 230)
            .background(colors.backgroundSidebar)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(colors.borderSubtle)
                    .frame(width: 1)
            }

            ZStack(alignment: .topTrailing) {
                Group {
                    switch selectedId {
                    case "aqua":
                        AquaProviderSettingsView(chatViewModel: chatViewModel)
                    case "statistics":
                        StatisticsView(chatViewModel: chatViewModel)
                    case "instructions":
                        CustomInstructionsSettingsView(chatViewModel: chatViewModel)
                    case "memory":
                        MemorySettingsView(chatViewModel: chatViewModel)
                    case "plugins":
                        PluginsSettingsView()
                    case "skills":
                        SkillsSettingsView()
                    case "imageProviders":
                        ImageProvidersSettingsView()
                    case "computer":
                        ComputerControlSettingsView()
                    case "localServer":
                        LocalAPIServerSettingsView()
                    case "appearance":
                        AppearanceSettingsView()
                    case "shortcuts":
                        ShortcutsSettingsView()
                    case "privacy":
                        PrivacySettingsView(chatViewModel: chatViewModel)
                    case "hardware":
                        HardwareSettingsView()
                    default:
                        if let config = config(for: selectedId) {
                            // `.id` forces SwiftUI to tear down and rebuild
                            // this view (including its @State) when the
                            // selected provider changes — without it, every
                            // custom provider hits this same `default` case
                            // at the same tree position, so SwiftUI reuses
                            // the previous provider's view instance and its
                            // stale `apiKeyInput`, leaking one provider's
                            // key into the next one's Save.
                            CustomProviderDetailSettingsView(chatViewModel: chatViewModel, config: config)
                                .id(config.id)
                        } else if selectedId.hasPrefix("local:"),
                           let backend = LocalBackend(rawValue: String(selectedId.dropFirst("local:".count))) {
                            LocalProviderSettingsView(chatViewModel: chatViewModel, backend: backend)
                        } else {
                            // Also the fallback for a deleted connection —
                            // e.g. removing this exact connection from its
                            // own detail page above leaves `selectedId`
                            // pointing at an id that no longer resolves.
                            GeneralSettingsView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colors.backgroundPrimary)

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(colors.backgroundSubtle))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(14)
            }
        }
        .frame(width: 980, height: 700)
        .background(colors.backgroundPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
        .sheet(isPresented: $isAddingProvider) {
            CustomProviderEditorSheet(
                chatViewModel: chatViewModel,
                existing: nil,
                onDone: finishAddingProvider,
                onWantsAqua: switchToAquaFromAddProvider
            )
        }
    }

    /// Pulled out of `card` as its own expression — inlined, this section
    /// (header + Aqua/BYOK/local rows) was enough on its own to tip
    /// SwiftUI's view-builder type-checker into "unable to type-check this
    /// expression in reasonable time," a timeout that surfaces as an
    /// unrelated-looking compile error somewhere else in the same giant
    /// expression rather than pointing at the actual cause.
    private var modelProvidersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("MODEL PROVIDERS")
                    .font(AppFont.mono(10, weight: .semibold))
                    .foregroundColor(colors.textTertiary)
                    .tracking(0.8)
                Spacer()
                Button {
                    isAddingProvider = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Add a custom provider")
            }
            .padding(.horizontal, 8)
            .padding(.top, 20)
            .padding(.bottom, 4)

            // Aqua isn't pre-added for a new install — it's one provider
            // option among several, not the app's default. It only earns
            // a permanent row once a key is actually saved; until then,
            // clicking "Add provider" opens the same neutral picker as
            // any other provider (not straight to an Aqua-branded page)
            // — Aqua is still reachable there as one of the picker's own
            // options, just not the thing you land on by default.
            if APIKeyStore.hasAPIKey {
                ForEach(providerCategories) { cat in
                    SettingsSidebarRow(category: cat, isSelected: selectedId == cat.id)
                        .onTapGesture { selectedId = cat.id }
                }
            } else {
                AddAquaRow { isAddingProvider = true }
            }

            ForEach(customStore.sortedConfigs) { config in
                CustomProviderSidebarRow(
                    config: config,
                    isSelected: selectedId == customProviderSelectionId(config),
                    isEnabled: !modelPrefs.isProviderDisabled(.custom(config.id))
                )
                .onTapGesture { selectedId = customProviderSelectionId(config) }
            }

            Text("LOCAL")
                .font(AppFont.mono(10, weight: .medium))
                .foregroundColor(colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 3)

            ForEach(LocalBackend.allCases) { backend in
                LocalBackendSidebarRow(
                    backend: backend,
                    isSelected: selectedId == "local:\(backend.rawValue)",
                    isInstalled: localManager.installed.contains(backend),
                    isActive: backend == .ollama
                        ? localManager.ollamaReachable
                        : localManager.activeSpawned?.backend == backend
                )
                .onTapGesture { selectedId = "local:\(backend.rawValue)" }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }
}

private struct SettingsSidebarRow: View {
    @Environment(\.themeColors) private var colors
    let category: SettingsCategory
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? colors.backgroundSelected : colors.backgroundSubtle)
                    .frame(width: 26, height: 26)
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? colors.textPrimary : colors.textSecondary)
            }

            Text(category.title)
                .font(AppFont.mono(13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? colors.textPrimary : colors.textPrimary.opacity(0.8))
                .lineLimit(1)

            if category.isBeta {
                BetaBadge()
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? colors.backgroundSelected : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

/// A small "BETA" pill — same visual language as `ModelLibraryView`'s
/// fit-estimate badges (tinted capsule, tiny mono caps), reused here for
/// any settings category or page that isn't fully settled yet.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(AppFont.mono(9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color(hex: "#F59E0B"))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(hex: "#F59E0B").opacity(0.14)))
    }
}

/// Shown instead of a permanent "Aqua API" row until a key is actually
/// saved — Aqua is offered, not pre-added, same as any other provider.
private struct AddAquaRow: View {
    @Environment(\.themeColors) private var colors
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(colors.borderMedium, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: 26, height: 26)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(colors.textTertiary)
                }
                Text("Add provider")
                    .font(AppFont.mono(13, weight: .regular))
                    .foregroundColor(colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Aqua's free hosted models — add a key to use it")
    }
}

/// A configured BYOK connection's row — real brand logo badge + company
/// name, plus a status dot matching the LOCAL section's own convention
/// (filled green when this connection is currently enabled).
private struct CustomProviderSidebarRow: View {
    @Environment(\.themeColors) private var colors
    @Bindable private var customStore = CustomProviderStore.shared
    let config: CustomProviderConfig
    let isSelected: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(brand: config.brand, size: 24, customImage: customStore.logoImage(for: config))

            Text(config.displayName)
                .font(AppFont.mono(13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? colors.textPrimary : colors.textPrimary.opacity(0.8))

            Spacer()

            if isEnabled {
                Circle()
                    .fill(Color(hex: "#34C759"))
                    .frame(width: 7, height: 7)
                    .help("Enabled")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? colors.backgroundSelected : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

/// A local backend's row (Ollama / Llama.cpp / MLX): tinted icon chip +
/// name + a status dot — filled when the backend is live, hollow when merely
/// installed, and the whole row dimmed when it isn't installed yet (still
/// clickable — its page is the install guide).
private struct LocalBackendSidebarRow: View {
    @Environment(\.themeColors) private var colors
    let backend: LocalBackend
    let isSelected: Bool
    let isInstalled: Bool
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(backend.tint.opacity(0.16))
                .overlay(Circle().stroke(colors.borderSubtle, lineWidth: 1))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: backend.systemIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(backend.tint)
                }
                .opacity(isInstalled ? 1 : 0.45)

            Text(backend.displayName)
                .font(AppFont.mono(13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isInstalled
                                 ? (isSelected ? colors.textPrimary : colors.textPrimary.opacity(0.8))
                                 : colors.textTertiary)

            Spacer()

            if isActive {
                Circle()
                    .fill(Color(hex: "#34C759"))
                    .frame(width: 7, height: 7)
                    .help("Running")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? colors.backgroundSelected : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.themeColors) private var colors
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(colors.backgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(colors.borderMedium, lineWidth: 1)
            )
            .shadow(color: colors.shadowColor, radius: 6, y: 2)
    }
}
