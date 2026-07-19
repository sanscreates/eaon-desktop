import SwiftUI

/// Settings → Device Control (formerly its own "Eaon Claw" mode with a
/// dedicated enable gate — folded into Agent mode now, see `EaonMode`). Off
/// by default — the master switch for letting Agent, in addition to coding,
/// organize files, run commands, and open/close/drive apps and websites on
/// this Mac. The page's job is disclosure: say plainly what it can do and
/// what keeps it safe, so turning it on is an informed choice, not a
/// mystery toggle.
struct ComputerControlSettingsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable private var store = DesktopControlStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Device Control")
                    .font(AppFont.mono(20, weight: .bold))
                    .foregroundColor(colors.textPrimary)
                BetaBadge()
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 8)

            Text("Let Agent act on this Mac when you ask — organize files, run commands, and open, close, and navigate apps and websites, on top of its usual coding tools. Off by default; nothing runs until you turn it on here.")
                .font(AppFont.sans(12))
                .foregroundColor(colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    toggleCard
                    canDoCard
                    safetyCard
                    permissionCard
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.backgroundPrimary)
    }

    private var toggleCard: some View {
        SettingsCard {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Let Eaon control this Mac")
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Text(store.isEnabled
                         ? "On — the model can act on your Mac when you ask it to. Each change asks first."
                         : "Off — the model can't touch your files, apps, or system.")
                        .font(AppFont.mono(11))
                        .foregroundColor(colors.textTertiary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $store.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AppearanceSettings.toggleTint)
            }
            .padding(16)
        }
    }

    private var canDoCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader("What it can do")
                capabilityRow("folder", "Organize files", "List, move, rename, and create folders — and send things to the Trash (never a permanent delete).")
                divider
                capabilityRow("terminal", "Run commands", "Run shell commands, the same as you would in Terminal — with a timeout and no admin (sudo) access.")
                divider
                capabilityRow("macwindow.on.rectangle", "Drive apps & websites", "Open and quit apps, open URLs, and use AppleScript to control scriptable apps and click menu items by name.")
            }
        }
    }

    private var safetyCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader("What keeps it safe")
                safetyRow("hand.raised.fill", "It asks before every change — you approve each action, or grant a whole chat at once and stop there.")
                divider
                safetyRow("trash.fill", "Deletions go to the Trash, so they're recoverable. There's no permanent-delete path.")
                divider
                safetyRow("lock.shield.fill", "No admin (sudo), no touching system files, and it will never enter passwords, buy anything, move money, or change account settings.")
                divider
                safetyRow("doc.text.magnifyingglass", "Text it reads from files, webpages, or command output is treated as information, not instructions — so a booby-trapped file can't quietly redirect it. Anything like that is surfaced to you.")
            }
        }
    }

    private var permissionCard: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(colors.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS will ask permission")
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Text("The first time Eaon drives another app, macOS prompts you to allow it under System Settings → Privacy & Security (Automation / Accessibility). If an action seems to do nothing, that permission is usually why — grant it there and try again.")
                        .font(AppFont.sans(11))
                        .foregroundColor(colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Row builders

    private func cardHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.mono(11, weight: .semibold))
            .foregroundColor(colors.textTertiary)
            .tracking(0.5)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    private var divider: some View {
        Divider().overlay(colors.borderSubtle).padding(.leading, 16)
    }

    private func capabilityRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(AppearanceSettings.shared.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.mono(13, weight: .medium))
                    .foregroundColor(colors.textPrimary)
                Text(detail)
                    .font(AppFont.sans(11))
                    .foregroundColor(colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func safetyRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(colors.textSecondary)
                .frame(width: 22)
            Text(text)
                .font(AppFont.sans(12))
                .foregroundColor(colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
