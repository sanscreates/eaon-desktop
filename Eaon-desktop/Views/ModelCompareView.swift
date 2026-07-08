import SwiftUI

struct ModelCompareView: View {
    @Environment(\.themeColors) private var colors
    @Bindable private var modelPrefs = ModelPreferencesStore.shared
    let availableModels: [APIModel]

    @State private var vm = CompareViewModel()
    @State private var showingSystemPrompt = false

    private var apiKey: String? { KeychainService.loadAPIKey() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            promptArea
            Divider()
            if vm.slots.count < 2 {
                addModelPrompt
            } else {
                responseColumns
            }
        }
        .background(colors.backgroundPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model Compare")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(colors.textPrimary)
                Text("Send the same prompt to up to 3 models side by side.")
                    .font(.system(size: 12))
                    .foregroundColor(colors.textSecondary)
            }

            Spacer()

            // System prompt toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingSystemPrompt.toggle() }
            } label: {
                Label("System Prompt", systemImage: "text.quote")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(showingSystemPrompt ? colors.textPrimary : colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(showingSystemPrompt ? colors.backgroundSelected : colors.backgroundInput)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            // Add model button
            if vm.slots.count < 3 {
                Menu {
                    ForEach(addableModels) { model in
                        Button(ModelCatalog.displayName(modelId: model.id, apiName: model.name)) {
                            vm.addSlot(modelId: model.id)
                        }
                    }
                } label: {
                    Label("Add Model", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(colors.backgroundInput)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Run button
            Button {
                guard let key = apiKey else { return }
                Task { await vm.run(apiKey: key) }
            } label: {
                HStack(spacing: 6) {
                    if vm.isRunning {
                        ProgressView().controlSize(.mini).tint(AppearanceSettings.shared.onAccentColor)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(vm.isRunning ? "Running…" : "Run")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(vm.canRun ? AppearanceSettings.shared.onAccentColor : colors.backgroundPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(vm.canRun ? AppearanceSettings.shared.accentColor : colors.textTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!vm.canRun || apiKey == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Prompt Area

    private var promptArea: some View {
        VStack(spacing: 0) {
            if showingSystemPrompt {
                HStack(spacing: 0) {
                    Text("System")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(colors.textTertiary)
                        .frame(width: 60, alignment: .leading)
                        .padding(.leading, 20)
                    TextField("Optional system prompt…", text: $vm.systemPrompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(colors.textPrimary)
                        .lineLimit(1...3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .background(colors.backgroundInputSecondary)
                Divider()
            }

            HStack(alignment: .bottom, spacing: 0) {
                Text("Prompt")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(colors.textTertiary)
                    .frame(width: 60, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.bottom, 12)

                TextField("Enter a prompt to compare across models…", text: $vm.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(colors.textPrimary)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .onSubmit {
                        guard let key = apiKey, vm.canRun else { return }
                        Task { await vm.run(apiKey: key) }
                    }
            }
        }
    }

    // MARK: - No-slot placeholder

    private var addModelPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 40))
                .foregroundColor(colors.textTertiary)
            Text("Add at least 2 models to compare")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(colors.textSecondary)
            Text("Use the + Add Model button above, then type a prompt and hit Run.")
                .font(.system(size: 13))
                .foregroundColor(colors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Response Columns

    private var responseColumns: some View {
        HStack(spacing: 0) {
            ForEach(Array(vm.slots.enumerated()), id: \.element.modelId) { index, slot in
                if index > 0 {
                    Divider()
                }
                CompareColumn(
                    slot: slot,
                    availableModels: availableModels,
                    onChangeModel: { newId in vm.setSlotModel(at: index, modelId: newId) },
                    onRemove: vm.slots.count > 2 ? { vm.removeSlot(at: index) } : nil
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addableModels: [APIModel] {
        let existing = Set(vm.slots.map(\.modelId))
        return availableModels.filter { !existing.contains($0.id) }
    }
}

// MARK: - Column

private struct CompareColumn: View {
    @Environment(\.themeColors) private var colors
    @Bindable private var modelPrefs = ModelPreferencesStore.shared
    @Bindable var slot: CompareSlot
    let availableModels: [APIModel]
    let onChangeModel: (String) -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            ScrollView {
                columnContent
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            BrandLogoView(brand: ModelCatalog.brand(for: slot.modelId), size: 18)

            Menu {
                ForEach(availableModels) { model in
                    Button(modelPrefs.nickname(for: model.id)
                           ?? ModelCatalog.displayName(modelId: model.id, apiName: model.name)) {
                        onChangeModel(model.id)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(modelPrefs.nickname(for: slot.modelId)
                         ?? ModelCatalog.displayName(modelId: slot.modelId, apiName: nil))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(colors.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)

            Spacer(minLength: 0)

            metricsView

            if let remove = onRemove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colors.backgroundSidebar)
    }

    @ViewBuilder
    private var metricsView: some View {
        if slot.isGenerating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Generating…")
                    .font(.system(size: 11))
                    .foregroundColor(colors.textTertiary)
            }
        } else if let tps = slot.tokensPerSecond, let lat = slot.latencySeconds {
            HStack(spacing: 10) {
                metricBadge(String(format: "%.1f tok/s", tps), icon: "bolt.fill", color: .orange)
                metricBadge(String(format: "%.1fs", lat), icon: "clock", color: colors.textTertiary)
                metricBadge("\(slot.generatedTokenCount) tok", icon: "number", color: colors.textTertiary)
            }
        }
    }

    private func metricBadge(_ label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(colors.backgroundSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private var columnContent: some View {
        if slot.content.isEmpty && !slot.isGenerating && !slot.isError {
            Text("Waiting for run…")
                .font(.system(size: 14))
                .foregroundColor(colors.textTertiary)
        } else if slot.isError {
            Label(slot.content, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(.red)
        } else {
            Text(slot.content)
                .font(.system(size: 14))
                .foregroundColor(colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            if slot.isGenerating {
                TypingCursor()
                    .padding(.top, 2)
            }
        }
    }
}

private struct TypingCursor: View {
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) { visible = false }
            }
    }
}
