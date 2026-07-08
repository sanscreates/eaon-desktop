import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Describes what this app actually does with your data — kept to verifiable
/// facts about the client's own behavior, not policy claims on Aqua Devs'
/// behalf that this app has no way to guarantee.
struct PrivacySettingsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var chatViewModel: ChatViewModel
    @State private var isConfirmingDeleteAll = false
    @State private var importResultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Privacy")
                .font(AppFont.mono(20, weight: .bold))
                .foregroundColor(colors.textPrimary)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dataCard
                    yourDataActionsCard
                    linkCard
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.backgroundPrimary)
        .alert(
            "Delete all chats and projects?",
            isPresented: $isConfirmingDeleteAll
        ) {
            Button("Delete Everything", role: .destructive) {
                chatViewModel.deleteAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every conversation and project on this Mac. It can't be undone — export first if you want a copy.")
        }
    }

    // MARK: - Your data

    private var yourDataActionsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your data")
                    .font(AppFont.mono(14, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                if let importResultMessage {
                    Text(importResultMessage)
                        .font(AppFont.mono(12))
                        .foregroundColor(colors.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                dataActionRow(
                    icon: "square.and.arrow.up",
                    title: "Export all chats",
                    detail: "Every conversation and project, as one JSON file.",
                    buttonTitle: "Export…"
                ) { exportAllData() }

                Divider().overlay(colors.borderSubtle).padding(.horizontal, 16)

                dataActionRow(
                    icon: "square.and.arrow.down",
                    title: "Import chats",
                    detail: "Adds chats from a previously-exported file — never overwrites what's already here.",
                    buttonTitle: "Import…"
                ) { importData() }

                Divider().overlay(colors.borderSubtle).padding(.horizontal, 16)

                dataActionRow(
                    icon: "trash",
                    title: "Delete all my data",
                    detail: "Removes every conversation and project on this Mac.",
                    buttonTitle: "Delete Everything",
                    isDestructive: true
                ) { isConfirmingDeleteAll = true }
            }
            .padding(.bottom, 6)
        }
    }

    private func dataActionRow(
        icon: String,
        title: String,
        detail: String,
        buttonTitle: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isDestructive ? colors.destructive : colors.textSecondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.mono(13, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                Text(detail)
                    .font(AppFont.sans(12))
                    .foregroundColor(colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action: action) {
                Text(buttonTitle)
                    .font(AppFont.mono(12, weight: .medium))
                    .foregroundColor(isDestructive ? colors.destructive : colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().stroke(isDestructive ? colors.destructive.opacity(0.5) : colors.borderMedium, lineWidth: 1))
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func exportAllData() {
        guard let data = chatViewModel.exportAllConversationsJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Eaon Chats.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let count = chatViewModel.importConversations(from: data)
        importResultMessage = count > 0
            ? "Imported \(count) chat\(count == 1 ? "" : "s")."
            : "Nothing new to import — those chats are already here."
    }

    private var dataCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                privacyRow(
                    icon: "key.fill",
                    title: "Your API key",
                    detail: "Stored in the macOS Keychain on this device. It's sent only as an authorization header when you send a message."
                )
                Divider().overlay(colors.borderSubtle)
                privacyRow(
                    icon: "paperplane.fill",
                    title: "Messages & attachments",
                    detail: "Sent to Aqua Devs' API (api.aquadevs.com) to generate a response — that's the only place they go."
                )
                Divider().overlay(colors.borderSubtle)
                privacyRow(
                    icon: "internaldrive.fill",
                    title: "Chat history",
                    detail: "Stored locally on this Mac. This app does not sync it to any server."
                )
            }
            .padding(18)
        }
    }

    private func privacyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(colors.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.mono(13, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                Text(detail)
                    .font(AppFont.sans(12))
                    .foregroundColor(colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var linkCard: some View {
        SettingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full privacy policy")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Text("For Aqua Devs' complete data and API policies.")
                        .font(AppFont.sans(12))
                        .foregroundColor(colors.textSecondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(string: "https://aquadevs.com")!)
                } label: {
                    HStack(spacing: 5) {
                        Text("aquadevs.com")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(AppFont.mono(12, weight: .medium))
                    .foregroundColor(colors.link)
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
    }
}
