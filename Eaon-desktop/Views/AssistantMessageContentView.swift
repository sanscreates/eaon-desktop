import SwiftUI

struct AssistantMessageContentView: View {
    let text: String
    let isTyping: Bool
    /// Called with a file path when the user clicks a workspace file card —
    /// nil (the default) leaves plain code-block rendering untouched for any
    /// caller that isn't wired into the workspace panel.
    var onOpenWorkspaceFile: ((String) -> Void)? = nil
    /// Real status text for a local model still loading — nil shows the
    /// plain pulsing dot exactly as before.
    var loadingStatusText: String? = nil

    private var blocks: [MessageBlock] {
        MessageContentParser.parse(text)
    }

    var body: some View {
        Group {
            if blocks.isEmpty {
                if isTyping {
                    ThinkingIndicator(statusText: loadingStatusText)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        blockView(block, index: index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(nil, value: text)
    }

    @ViewBuilder
    private func blockView(_ block: MessageBlock, index: Int) -> some View {
        let isLast = index == blocks.count - 1
        let showCursor = isTyping && isLast

        switch block {
        case .text(let content):
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownBlockView(text: content)
            } else if showCursor {
                ThinkingIndicator()
            }

        case .code(let language, let code):
            // aqua:* fences are agent tool requests (run/edit/read/ls) — a
            // small action chip; a fence carrying a file attribute is a
            // workspace file — a compact card (the code itself lives in the
            // workspace panel, the way Cursor/Lovable summarize in chat).
            let fence = WorkspaceParser.fenceInfo(from: language)
            if let fenceLanguage = fence.language, fenceLanguage.hasPrefix("aqua:"), fenceLanguage != "aqua:write" {
                ToolActionChip(kindToken: fenceLanguage, path: fence.path, isStreaming: showCursor)
            } else if let path = fence.path {
                WorkspaceFileCard(path: path, code: code, isStreaming: showCursor) {
                    onOpenWorkspaceFile?(path)
                }
            } else {
                CodeBlockView(
                    language: language,
                    code: code,
                    showTypingCursor: showCursor
                )
            }
        }
    }
}

/// Inline chip for an agent tool request (run/edit/read/ls). The request is
/// summarized here; its outcome arrives in the following results card and
/// streams into the workspace console.
struct ToolActionChip: View {
    @Environment(\.themeColors) private var colors
    let kindToken: String
    let path: String?
    var isStreaming: Bool = false

    private var kind: String { String(kindToken.dropFirst("aqua:".count)) }

    private var icon: String {
        switch kind {
        case "run": return "play.fill"
        case "edit": return "pencil"
        case "read": return "eye"
        default: return "list.bullet"
        }
    }

    private var label: String {
        switch kind {
        case "run": return "Run \(path ?? "")"
        case "edit": return "Edit \(path ?? "")"
        case "read": return "Read \(path ?? "")"
        case "ls", "list": return "List files"
        default: return kindToken
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.textSecondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colors.backgroundChipSecondary)
                )
            Text(label.trimmingCharacters(in: .whitespaces))
                .font(AppFont.mono(12, weight: .medium))
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)
            if isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(colors.backgroundChip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }
}

/// Chat-side stand-in for a file the model created: filename, live line
/// count, and a click-through into the workspace panel's editor.
struct WorkspaceFileCard: View {
    @Environment(\.themeColors) private var colors
    let path: String
    let code: String
    var isStreaming: Bool = false
    var onOpen: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: WorkspaceFileIcon.systemName(forPath: path))
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(colors.backgroundChipSecondary)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(AppFont.mono(12.5, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(AppFont.mono(11))
                        .foregroundStyle(colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isStreaming {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(colors.textTertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? colors.backgroundHover : colors.backgroundChip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open in workspace")
    }

    private var subtitle: String {
        let lines = code.isEmpty ? 0 : code.components(separatedBy: "\n").count
        return isStreaming
            ? "Writing… \(lines) line\(lines == 1 ? "" : "s")"
            : "\(lines) line\(lines == 1 ? "" : "s") · Open in workspace"
    }
}

/// A soft pulsing dot shown while the assistant is preparing its first
/// tokens — optionally paired with real status text (e.g. a local model
/// still loading into memory) rather than leaving that wait unexplained.
struct ThinkingIndicator: View {
    @Environment(\.themeColors) private var colors
    @State private var pulse = false
    var statusText: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colors.textPrimary)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.25 : 0.9)
                .scaleEffect(pulse ? 0.85 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            if let statusText {
                Text(statusText)
                    .font(AppFont.mono(13))
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .onAppear { pulse = true }
    }
}
