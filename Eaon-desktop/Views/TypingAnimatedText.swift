import SwiftUI

struct TypingAnimatedText: View {
    @Environment(\.themeColors) private var colors
    let text: String
    let isTyping: Bool

    private var messageFontSize: CGFloat {
        AppearanceSettings.shared.fontSize.messageFontSize
    }

    var body: some View {
        Group {
            if isTyping {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let cursorVisible = Int(context.date.timeIntervalSince1970 * 2) % 2 == 0
                    inlineText(cursorVisible: cursorVisible)
                }
            } else {
                Text(text)
                    .font(.system(size: messageFontSize))
                    .foregroundStyle(colors.textPrimary)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(nil, value: text)
    }

    private func inlineText(cursorVisible: Bool) -> Text {
        let body = Text(text).font(.system(size: messageFontSize)).foregroundColor(colors.textPrimary)
        let cursor = Text("▎").font(.system(size: messageFontSize)).foregroundColor(colors.textPrimary.opacity(cursorVisible ? 0.95 : 0.2))
        return body + cursor
    }
}
