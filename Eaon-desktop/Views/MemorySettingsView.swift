import SwiftUI

/// Settings → Memory. Off by default — nothing is stored or sent until the
/// user turns it on here. Every remembered fact is listed, individually
/// deletable, and can also be added by hand: automatic extraction is a
/// convenience, not the only way in or out.
struct MemorySettingsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable private var store = MemoryStore.shared
    @Bindable var chatViewModel: ChatViewModel
    @State private var draft = ""
    @State private var showingClearConfirm = false
    /// Non-nil while the learn-from-file confirmation is up — the second
    /// half of that flow's heavy consent (the explicit file pick being the
    /// first). Holds the picked file so Confirm knows what to act on.
    @State private var pendingFileToLearn: URL?
    @FocusState private var isFocused: Bool

    private var isAddDisabled: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isFull
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Memory")
                .font(AppFont.mono(20, weight: .bold))
                .foregroundColor(colors.textPrimary)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 8)

            Text("When on, Eaon remembers what you share — who you are, what you're working on, and what's been happening in your life — and brings it into future chats naturally, like talking to someone who knows you. Nothing is extracted or sent anywhere until you turn this on, and you can review or delete anything it remembers, any time.")
                .font(AppFont.sans(12))
                .foregroundColor(colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    toggleCard
                    backfillCard
                    fileLearnCard
                    addCard
                    memoriesCard
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.backgroundPrimary)
        .alert("Clear all memories?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { store.clearAll() }
        } message: {
            Text("This removes everything Eaon remembers about you. It can't be undone.")
        }
        .alert(
            "Learn from \"\(pendingFileToLearn?.lastPathComponent ?? "file")\"?",
            isPresented: Binding(
                get: { pendingFileToLearn != nil },
                set: { if !$0 { pendingFileToLearn = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingFileToLearn = nil }
            Button("Learn") {
                if let url = pendingFileToLearn { chatViewModel.learnFromFile(url: url) }
                pendingFileToLearn = nil
            }
        } message: {
            Text("Up to the first \(MemoryExtractor.maxFileCharacters / 1000),000 characters of this file's text will be sent to your currently selected model to find things worth remembering. The file itself stays on this Mac, and everything learned appears below for review.")
        }
    }

    private var toggleCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remember things about you")
                            .font(AppFont.mono(13, weight: .semibold))
                            .foregroundColor(colors.textPrimary)
                        Text(store.isEnabled ? "On — new chats can see what's remembered below." : "Off — nothing is stored or sent.")
                            .font(AppFont.mono(11))
                            .foregroundColor(colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $store.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(AppearanceSettings.shared.accentColor)
                }
                .padding(16)

                Divider().overlay(colors.borderSubtle)

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Automatically learn new things")
                            .font(AppFont.mono(13, weight: .semibold))
                            .foregroundColor(store.isEnabled ? colors.textPrimary : colors.textTertiary)
                        Text("Silently reviews each message you send for facts about you and happenings in your life. Off just stops new memories from being added — what's already remembered keeps working, and \"Learn from your existing chats\" below still runs whenever you ask it to.")
                            .font(AppFont.sans(11))
                            .foregroundColor(colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.isEnabled, store.isAutoLearnEnabled, let summary = store.lastAutoLearnSummary {
                            Text(summary)
                                .font(AppFont.mono(11))
                                .foregroundColor(colors.textSecondary)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $store.isAutoLearnEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(AppearanceSettings.shared.accentColor)
                        .disabled(!store.isEnabled)
                }
                .padding(16)
                .opacity(store.isEnabled ? 1 : 0.5)

                Divider().overlay(colors.borderSubtle)

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Also learn from connected plugins")
                            .font(AppFont.mono(13, weight: .semibold))
                            .foregroundColor(store.isEnabled ? colors.textPrimary : colors.textTertiary)
                        Text("When a chat uses a connected service (your calendar, issues, documents…), what it returned can be remembered too. Off — the default — means memory only ever considers what you and the model wrote, never plugin results.")
                            .font(AppFont.sans(11))
                            .foregroundColor(colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $store.isPluginLearnEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(AppearanceSettings.shared.accentColor)
                        .disabled(!store.isEnabled || !store.isAutoLearnEnabled)
                }
                .padding(16)
                .opacity(store.isEnabled && store.isAutoLearnEnabled ? 1 : 0.5)
            }
        }
    }

    /// Learn from a file the user explicitly picks — the "heavy consent"
    /// path: an open panel (nothing is ever scanned uninvited), then a
    /// confirmation spelling out exactly what gets sent where, then a
    /// reviewable result. Never recursive, never a folder, one file at a
    /// time.
    @ViewBuilder
    private var fileLearnCard: some View {
        if store.isEnabled {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Learn from a file on this Mac")
                                .font(AppFont.mono(13, weight: .semibold))
                                .foregroundColor(colors.textPrimary)
                            Text("Pick a text file (notes, a journal, a bio…) and Eaon extracts things worth remembering from it. Only the file you pick is read, only after you confirm, and everything learned shows up below for review.")
                                .font(AppFont.sans(11))
                                .foregroundColor(colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if chatViewModel.isLearningFromFile {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Choose File…") { pickFileToLearn() }
                                .buttonStyle(.bordered)
                                .disabled(store.isFull)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func pickFileToLearn() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.text]
        panel.message = "Choose a text file for Eaon to learn from"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingFileToLearn = url
    }

    /// Mines facts out of chats that already exist — not just ones going
    /// forward. Explicit and opt-in (a real API call per chat, which
    /// costs time and, on a paid model, money), so this is a button the
    /// user presses, never something that runs on its own.
    @ViewBuilder
    private var backfillCard: some View {
        if store.isEnabled {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Learn from your existing chats")
                                .font(AppFont.mono(13, weight: .semibold))
                                .foregroundColor(colors.textPrimary)
                            Text("Reviews every saved chat for durable facts, using whichever model is currently selected. One request per chat — may take a while and use real API calls.")
                                .font(AppFont.sans(11))
                                .foregroundColor(colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if chatViewModel.isBackfillingMemory {
                            Button("Stop") { chatViewModel.cancelMemoryBackfill() }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Learn Now") { chatViewModel.startMemoryBackfill() }
                                .buttonStyle(.bordered)
                                .disabled(store.isFull)
                        }
                    }

                    if chatViewModel.isBackfillingMemory {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            if let status = chatViewModel.memoryBackfillStatus {
                                Text(status)
                                    .font(AppFont.mono(11))
                                    .foregroundColor(colors.textSecondary)
                            }
                        }
                    } else if let status = chatViewModel.memoryBackfillStatus {
                        Text(status)
                            .font(AppFont.mono(11))
                            .foregroundColor(colors.textSecondary)
                    }
                }
                .padding(16)
            }
        }
    }

    private var addCard: some View {
        SettingsCard {
            HStack(spacing: 10) {
                TextField("Add something for Eaon to remember…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(AppFont.sans(13))
                    .foregroundColor(colors.textPrimary)
                    .focused($isFocused)
                    .onSubmit(addDraft)

                Button("Add", action: addDraft)
                    .buttonStyle(PressableButtonStyle())
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundColor(isAddDisabled ? colors.textSecondary : AppearanceSettings.shared.onAccentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(isAddDisabled ? colors.borderMedium : AppearanceSettings.shared.accentColor))
                    .disabled(isAddDisabled)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var memoriesCard: some View {
        if store.memories.isEmpty {
            SettingsCard {
                VStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 20))
                        .foregroundColor(colors.textTertiary)
                    Text("Nothing remembered yet")
                        .font(AppFont.mono(12, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            }
        } else {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("\(store.memories.count) REMEMBERED")
                            .font(AppFont.mono(10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundColor(colors.textTertiary)
                        Spacer()
                        Button("Clear All") { showingClearConfirm = true }
                            .buttonStyle(.plain)
                            .font(AppFont.mono(11, weight: .medium))
                            .foregroundColor(colors.destructive)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                    ForEach(store.memories) { item in
                        memoryRow(item)
                        if item.id != store.memories.last?.id {
                            Divider().overlay(colors.borderSubtle).padding(.leading, 16)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func memoryRow(_ item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(AppFont.sans(13))
                    .foregroundColor(colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // Events show when they were mentioned — that date is what
                // makes "how did Friday's final go?" possible, so it's
                // worth surfacing to the user too. Facts stay undated:
                // they're meant to be currently true, and a stale-looking
                // date would just invite doubt about a fact that's fine.
                if item.resolvedKind == .event {
                    Text(item.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(AppFont.mono(10.5))
                        .foregroundColor(colors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.resolvedKind == .event {
                Text("Event")
                    .font(AppFont.mono(10, weight: .medium))
                    .foregroundColor(colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(colors.backgroundChipSecondary))
            }

            Button {
                withAnimation(.uiEaseOut(duration: 0.2)) { store.remove(item.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(colors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func addDraft() {
        guard store.addManual(draft) else { return }
        draft = ""
        isFocused = true
    }
}
