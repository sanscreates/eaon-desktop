import SwiftUI

struct AquaProviderSettingsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var chatViewModel: ChatViewModel
    @Bindable private var modelPrefs = ModelPreferencesStore.shared

    @State private var apiKeyInput = ""
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveFailed = false

    @State private var editingModel: APIModel?
    @State private var nicknameDraft = ""
    @State private var modelPendingDeletion: APIModel?

    // "White" as an accent reads fine as a fill, but as bare text on this
    // page's own background it can vanish in light mode — fall back to the
    // normal readable text color for that one option.
    private var confirmationTextColor: Color {
        AppearanceSettings.shared.accentColorId == "white" ? colors.textPrimary : AppearanceSettings.shared.accentColor
    }

    private var visibleModels: [APIModel] {
        chatViewModel.availableModels
            .filter(\.isChatModel)
            .filter { !modelPrefs.isHidden($0.id) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Eaon API")
                .font(AppFont.mono(20, weight: .bold))
                .foregroundColor(colors.textPrimary)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    providerCard
                    freeWeekCard
                    apiKeyCard
                    modelsCard
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.backgroundPrimary)
        .onAppear {
            apiKeyInput = APIKeyStore.loadAPIKey() ?? ""
            AppFocus.activate()
            if chatViewModel.availableModels.isEmpty, !chatViewModel.isLoadingModels {
                Task { await chatViewModel.fetchModels() }
            }
            // Fresh days-left/usage numbers whenever the page opens (also
            // how a server-side revocation gets noticed).
            if TrialStore.shared.isActive {
                Task { await TrialStore.shared.refreshStatus() }
            }
        }
        .sheet(item: $editingModel) { model in
            ModelNicknameEditorSheet(
                modelId: model.id,
                nickname: $nicknameDraft,
                onSave: {
                    chatViewModel.setModelNickname(nicknameDraft, for: model.id)
                    editingModel = nil
                },
                onCancel: {
                    editingModel = nil
                }
            )
        }
        .alert(
            "Remove model?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { model in
            Button("Remove", role: .destructive) {
                chatViewModel.hideModel(model.id)
                modelPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                modelPendingDeletion = nil
            }
        } message: { model in
            Text("\(model.id) will be hidden from the model picker. You can restore it from the + menu in Models.")
        }
    }

    private var providerCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                AquaMark(size: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Eaon API")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Text("Hosted models via your Eaon API key")
                        .font(AppFont.mono(12))
                        .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { !modelPrefs.isProviderDisabled(.aqua) },
                    set: { _ in chatViewModel.toggleProvider(.aqua) }
                ))
                .toggleStyle(.switch)
                .tint(AppearanceSettings.toggleTint)
                .help(modelPrefs.isProviderDisabled(.aqua) ? "Turn Eaon back on" : "Turn Eaon off — every model it serves stops working")
            }
            .padding(16)
        }
    }

    /// The Free Week — one click, no signup, 7 days of hosted models
    /// through Eaon's own gateway. The credential is minted per device,
    /// never displayed, and a user's own key always takes precedence.
    @ViewBuilder
    private var freeWeekCard: some View {
        let trial = TrialStore.shared
        let hasUserKey = APIKeyStore.hasAPIKey

        // With a user key saved and no trial history, this card has nothing
        // to say — the account key already covers everything the trial does.
        if !(hasUserKey && trial.credential == nil) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Free Week")
                            .font(AppFont.mono(14, weight: .semibold))
                            .foregroundColor(colors.textPrimary)
                        if trial.isActive {
                            Text("\(trial.daysLeft) day\(trial.daysLeft == 1 ? "" : "s") left")
                                .font(AppFont.mono(10.5, weight: .semibold))
                                .foregroundColor(Color(hex: "#34C759"))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(hex: "#34C759").opacity(0.14)))
                        } else if trial.isExpired {
                            Text("Ended")
                                .font(AppFont.mono(10.5, weight: .semibold))
                                .foregroundColor(colors.textTertiary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(colors.backgroundChipSecondary))
                        }
                    }

                    if trial.isActive {
                        if hasUserKey {
                            Text("Your own API key is saved, so it's being used instead of the trial.")
                                .font(AppFont.sans(12))
                                .foregroundColor(colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Hosted models are on the house through \(trial.credential.map { Self.expiryFormatter.string(from: $0.expiresAt) } ?? "the end of the week")\(trialUsageSuffix). No account, no card — the trial runs through Eaon's own servers, and no API key is ever stored in the app.")
                                .font(AppFont.sans(12))
                                .foregroundColor(colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if trial.isExpired {
                        Text("Your free week has ended. Add your own Eaon API key below — creating one is free at eaon.dev.")
                            .font(AppFont.sans(12))
                            .foregroundColor(colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Try every hosted model free for 7 days — one click, no account, no card. The trial is tied to this Mac and runs through Eaon's own servers, so no API key is ever stored in the app.")
                            .font(AppFont.sans(12))
                            .foregroundColor(colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            AccentButton(
                                title: trial.isStarting ? "Starting…" : "Start Free Week",
                                isDisabled: trial.isStarting
                            ) {
                                Task {
                                    await TrialStore.shared.start()
                                    if TrialStore.shared.isActive {
                                        await chatViewModel.fetchModels()
                                        await TrialStore.shared.refreshStatus()
                                    }
                                }
                            }
                            Spacer()
                        }

                        if let error = trial.lastError {
                            Text(error)
                                .font(AppFont.sans(11.5))
                                .foregroundColor(colors.destructive)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var trialUsageSuffix: String {
        guard let used = TrialStore.shared.usage, let total = TrialStore.shared.totalRequests else { return "" }
        return " (\(used) of \(total) requests used)"
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private var apiKeyCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("API Key")
                    .font(AppFont.mono(14, weight: .semibold))
                    .foregroundColor(colors.textPrimary)

                Text("Your key stays on this device — saved locally in the app's own settings, sent only as an authorization header when you send a message.")
                    .font(AppFont.sans(12))
                    .foregroundColor(colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    SecureField("Paste your Eaon API key", text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .font(AppFont.mono(13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(colors.backgroundInput)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(colors.borderSubtle, lineWidth: 1)
                        )

                    AccentButton(title: "Save", isDisabled: isSaving) { saveAPIKey() }
                }

                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundColor(saveFailed ? colors.destructive : confirmationTextColor)
                }

                if APIKeyStore.hasAPIKey {
                    Label("API key saved on this device", systemImage: "lock.fill")
                        .font(AppFont.mono(12))
                        .foregroundColor(colors.textTertiary)
                }
            }
            .padding(16)
        }
    }

    private var modelsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Models")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)

                    Spacer()

                    HStack(spacing: 4) {
                        Button {
                            Task { await chatViewModel.fetchModels() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(colors.textSecondary)
                                .iconHoverEffect(for: "arrow.clockwise")
                                .frame(width: 28, height: 28)
                                .background(colors.backgroundInput)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(chatViewModel.isLoadingModels)
                        .help("Refresh models from API")

                        if !modelPrefs.hiddenModelIDs.isEmpty {
                            Menu {
                                ForEach(modelPrefs.hiddenModelsSorted, id: \.self) { modelId in
                                    Button(modelId) {
                                        chatViewModel.restoreModel(modelId)
                                    }
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(colors.textSecondary)
                                    .iconHoverEffect(for: "plus")
                                    .frame(width: 28, height: 28)
                                    .background(colors.backgroundInput)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .menuStyle(.borderlessButton)
                            .help("Restore removed models")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                if chatViewModel.isLoadingModels {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading models…")
                            .font(AppFont.mono(13))
                            .foregroundColor(colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                } else if let error = chatViewModel.modelsLoadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Could not load models")
                            .font(AppFont.mono(13, weight: .semibold))
                            .foregroundColor(colors.textPrimary)
                        Text(error)
                            .font(AppFont.mono(12))
                            .foregroundColor(colors.textSecondary)
                        Button("Retry") {
                            Task { await chatViewModel.fetchModels() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                } else if visibleModels.isEmpty {
                    Text("No models available.")
                        .font(AppFont.mono(13))
                        .foregroundColor(colors.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                            modelRow(model)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private func modelRow(_ model: APIModel) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.id)
                        .font(AppFont.mono(13, weight: .medium))
                        .foregroundColor(colors.textPrimary)

                    if ModelCatalog.supportsVision(for: model.id) {
                        Image(systemName: "eye")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(colors.textTertiary)
                            .help("Supports vision")
                    }
                }

                Text(rowSubtitle(for: model))
                    .font(AppFont.mono(11))
                    .foregroundColor(modelPrefs.nickname(for: model.id) != nil ? colors.textSecondary : colors.textTertiary)
            }

            Spacer()

            HStack(spacing: 2) {
                // Favorite toggle
                Button {
                    modelPrefs.toggleFavorite(model.id)
                } label: {
                    Image(systemName: modelPrefs.isFavorite(model.id) ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundColor(modelPrefs.isFavorite(model.id) ? .yellow : colors.textSecondary)
                        .iconHoverEffect(for: "star")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(modelPrefs.isFavorite(model.id) ? "Remove from favorites" : "Add to favorites")

                Button {
                    nicknameDraft = modelPrefs.nickname(for: model.id)
                        ?? defaultCatalogName(for: model)
                    editingModel = model
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                        .iconHoverEffect(for: "square.and.pencil")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Edit nickname")

                Button {
                    modelPendingDeletion = model
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)
                        .iconHoverEffect(for: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func rowSubtitle(for model: APIModel) -> String {
        if let nickname = modelPrefs.nickname(for: model.id) {
            return nickname
        }
        let defaultName = defaultCatalogName(for: model)
        return defaultName == model.id ? "No custom nickname" : defaultName
    }

    private func defaultCatalogName(for model: APIModel) -> String {
        EaonHostedModels.defaultDisplayName(for: model.id, apiName: model.name)
    }

    private func saveAPIKey() {
        isSaving = true
        saveMessage = nil
        saveFailed = false

        do {
            try APIKeyStore.saveAPIKey(apiKeyInput)
            saveMessage = "API key saved."
            saveFailed = false
        } catch {
            saveMessage = error.localizedDescription
            saveFailed = true
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        }

        isSaving = false
    }
}

struct ModelNicknameEditorSheet: View {
    @Environment(\.themeColors) private var colors
    let modelId: String
    @Binding var nickname: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Nickname")
                .font(AppFont.mono(16, weight: .semibold))
                .foregroundColor(colors.textPrimary)

            Text(modelId)
                .font(AppFont.mono(12))
                .foregroundColor(colors.textSecondary)

            TextField("Nickname", text: $nickname)
                .textFieldStyle(.plain)
                .font(AppFont.mono(14))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(colors.backgroundInput)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(colors.borderSubtle, lineWidth: 1)
                )

            Text("Leave blank to use the default name.")
                .font(AppFont.mono(11))
                .foregroundColor(colors.textTertiary)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                AccentButton(title: "Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(colors.backgroundPrimary)
    }
}
