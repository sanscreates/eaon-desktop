import SwiftUI

/// Per-model "run on CPU/GPU" control for a llama.cpp model, mapped to
/// `-ngl` (see `GPUOffloadMode`). Shared by `ModelLibraryView`'s combined
/// list and `LocalProviderSettingsView`'s per-backend page so both surfaces
/// stay in sync without duplicating the menu.
struct GPUModeMenu: View {
    @Environment(\.themeColors) private var colors
    @Bindable var manager: LocalAIManager
    let record: LocalModelRecord

    private var currentMode: GPUOffloadMode { record.gpuMode ?? .auto }

    var body: some View {
        Menu {
            ForEach(GPUOffloadMode.allCases) { mode in
                Button {
                    manager.setGPUMode(mode, for: record.id)
                } label: {
                    if mode == currentMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            Image(systemName: "cpu")
                .font(.system(size: 12))
                .foregroundColor(colors.textSecondary)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Run on: \(currentMode.label) — \(currentMode.helpText)")
    }
}
