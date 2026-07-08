import SwiftUI

/// The floating "New Version" card — download icon, version headline, and
/// the Show Release Notes / Remind Me Later / Update Now row, matching the
/// reference. Appears bottom-trailing over the chat, never blocks anything.
struct UpdateBanner: View {
    @Environment(\.themeColors) private var colors
    @Bindable private var checker = UpdateChecker.shared
    let manifest: UpdateManifest

    @State private var showingNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text("New Version \(manifest.latestVersion)")
                        .font(AppFont.mono(15, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text("Update Available")
                        .font(AppFont.mono(13))
                        .foregroundStyle(colors.textSecondary)
                }
            }

            if showingNotes, let notes = manifest.releaseNotes, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(AppFont.sans(12))
                        .foregroundStyle(colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }

            switch checker.downloadState {
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction {
                        ProgressView(value: fraction)
                        Text("Downloading… \(Int(fraction * 100))%")
                            .font(AppFont.mono(12))
                            .foregroundStyle(colors.textSecondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading…")
                            .font(AppFont.mono(12))
                            .foregroundStyle(colors.textSecondary)
                    }
                }
            case .opened(let filename):
                Text("Downloaded \(filename) and opened it — quit Eaon and drag the new version into Applications to finish.")
                    .font(AppFont.sans(12))
                    .foregroundStyle(colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(AppFont.sans(12))
                    .foregroundStyle(colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                actionRow
            case .idle:
                actionRow
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colors.backgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            if let notes = manifest.releaseNotes, !notes.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showingNotes.toggle() }
                } label: {
                    Text(showingNotes ? "Hide Release Notes" : "Show Release Notes")
                        .font(AppFont.mono(13, weight: .medium))
                        .foregroundStyle(colors.textPrimary)
                }
                .buttonStyle(.plain)
            }

            Button {
                checker.remindLater()
            } label: {
                Text("Remind Me Later")
                    .font(AppFont.mono(13, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                checker.updateNow()
            } label: {
                Text("Update Now")
                    .font(AppFont.mono(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(AppearanceSettings.shared.accentColor))
            }
            .buttonStyle(PressableButtonStyle())
        }
    }
}
