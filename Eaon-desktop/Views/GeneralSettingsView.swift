import AppKit
import SwiftUI

/// The "General" settings pane — app identity and support links. Previously
/// this tab fell through to a generic placeholder ("Configuration options
/// will appear here"); this is the real content.
struct GeneralSettingsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable private var updateChecker = UpdateChecker.shared

    // The dev build is a bare executable with no Info.plist, so the bundle
    // never has a version — `AppVersion.current` is the source of truth.
    private var appVersion: String { AppVersion.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(AppFont.mono(20, weight: .bold))
                .foregroundColor(colors.textPrimary)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    aboutCard
                    updatesCard
                    supportCard
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.backgroundPrimary)
    }

    private var aboutCard: some View {
        SettingsCard {
            HStack(spacing: 16) {
                AquaMark(size: 44)

                VStack(alignment: .leading, spacing: 4) {
                    AquaWordmark(size: 18)
                    Text("Unified Free AI API Platform for Top Models")
                        .font(AppFont.sans(12))
                        .foregroundColor(colors.textSecondary)
                    Text("Version \(appVersion)")
                        .font(AppFont.mono(11))
                        .foregroundColor(colors.textTertiary)
                }

                Spacer(minLength: 0)

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

    private var updatesCard: some View {
        SettingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Updates")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    if let result = updateChecker.lastManualCheckResult {
                        Text(result)
                            .font(AppFont.mono(12))
                            .foregroundColor(colors.textSecondary)
                    } else {
                        Text("Eaon checks for new versions automatically when it starts.")
                            .font(AppFont.mono(12))
                            .foregroundColor(colors.textSecondary)
                    }
                }
                Spacer()
                Button {
                    Task { await updateChecker.checkManually() }
                } label: {
                    HStack(spacing: 6) {
                        if updateChecker.isCheckingManually {
                            ProgressView().controlSize(.small)
                        }
                        Text("Check for Updates")
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(colors.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().stroke(colors.borderMedium, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(updateChecker.isCheckingManually)
            }
            .padding(18)
        }
    }

    private var supportCard: some View {
        SettingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Need help?")
                        .font(AppFont.mono(14, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                    Text("support@aquadevs.com")
                        .font(AppFont.mono(12))
                        .foregroundColor(colors.textSecondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(string: "mailto:support@aquadevs.com")!)
                } label: {
                    Text("Email us")
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundColor(colors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().stroke(colors.borderMedium, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(18)
        }
    }

}
