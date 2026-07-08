import SwiftUI

/// A polished empty-state panel for sidebar destinations that aren't wired to a
/// full experience yet (Images, Apps, Codex, Projects). Keeps the app feeling
/// complete rather than exposing dead buttons.
struct FeaturePlaceholderView: View {
    @Environment(\.themeColors) private var colors
    let feature: AppFeature

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(feature.rawValue)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .overlay(alignment: .bottom) {
                Rectangle().fill(colors.borderSubtle).frame(height: 1)
            }

            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(colors.backgroundSubtle)
                        .frame(width: 72, height: 72)
                    Image(systemName: feature.icon)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(colors.textSecondary)
                }
                Text(feature.rawValue)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                Text(feature.blurb)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Text("Coming soon to Aqua")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(colors.backgroundSubtle))
                    .padding(.top, 4)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.backgroundPrimary)
    }
}
