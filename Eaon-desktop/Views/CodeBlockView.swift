import AppKit
import SwiftUI

struct CodeBlockView: View {
    @Environment(\.themeColors) private var colors
    let language: String?
    let code: String
    var showTypingCursor: Bool = false

    @State private var copied = false

    private var displayLanguage: String {
        guard let language, !language.isEmpty else { return "code" }
        return language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    codeText
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 420)
            .background(colors.backgroundCode)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(displayLanguage)
                .font(AppFont.mono(12, weight: .medium))
                .foregroundStyle(colors.textSecondary)

            Spacer()

            Button(action: copyCode) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied" : "Copy")
                }
                .font(AppFont.mono(12, weight: .medium))
                .foregroundStyle(copied ? Color.green : colors.textPrimary.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(colors.backgroundCodeHeader)
    }

    @ViewBuilder
    private var codeText: some View {
        if showTypingCursor {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let cursorVisible = Int(context.date.timeIntervalSince1970 * 2) % 2 == 0
                (Text(code).foregroundColor(colors.textCode)
                    + Text("▎").foregroundColor(colors.textPrimary.opacity(cursorVisible ? 0.95 : 0.2)))
                    .font(AppFont.mono(13))
                    .textSelection(.enabled)
            }
        } else {
            Text(code)
                .font(AppFont.mono(13))
                .foregroundStyle(colors.textCode)
                .textSelection(.enabled)
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
