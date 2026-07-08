import SwiftUI

/// Renders a plain-markdown text segment (no fenced code — that is handled
/// upstream) into ChatGPT-style typographic blocks: headings, paragraphs,
/// bullet / numbered lists, blockquotes and horizontal rules. Inline emphasis,
/// `code`, and [links](…) are rendered via AttributedString.
struct MarkdownBlockView: View {
    @Environment(\.themeColors) private var colors
    let text: String

    private var fontSize: CGFloat { AppearanceSettings.shared.fontSize.messageFontSize }

    private var lines: [MarkdownLine] {
        MarkdownLineParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(for: line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for line: MarkdownLine) -> some View {
        switch line {
        case .heading(let level, let content):
            inline(content)
                .font(AppFont.sans(headingSize(level), weight: .semibold))
                .foregroundStyle(colors.textPrimary)
                .padding(.top, level <= 2 ? 14 : 10)
                .padding(.bottom, 4)
                .textSelection(.enabled)

        case .paragraph(let content):
            inline(content)
                .font(AppFont.sans(fontSize))
                .foregroundStyle(colors.textPrimary)
                .lineSpacing(3)
                .padding(.vertical, 4)
                .textSelection(.enabled)

        case .bullet(let indent, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(colors.textSecondary)
                    .frame(width: 5, height: 5)
                    .padding(.top, fontSize * 0.42)
                inline(content)
                    .font(AppFont.sans(fontSize))
                    .foregroundStyle(colors.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 18)
            .padding(.vertical, 3)
            .textSelection(.enabled)

        case .numbered(let indent, let number, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(AppFont.sans(fontSize, weight: .medium))
                    .foregroundStyle(colors.textSecondary)
                    .monospacedDigit()
                inline(content)
                    .font(AppFont.sans(fontSize))
                    .foregroundStyle(colors.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 18)
            .padding(.vertical, 3)
            .textSelection(.enabled)

        case .quote(let content):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(colors.borderMedium)
                    .frame(width: 3)
                inline(content)
                    .font(AppFont.sans(fontSize))
                    .foregroundStyle(colors.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .textSelection(.enabled)

        case .rule:
            Rectangle()
                .fill(colors.borderSubtle)
                .frame(height: 1)
                .padding(.vertical, 12)

        case .spacer:
            Color.clear.frame(height: 6)
        }
    }

    private func inline(_ raw: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attributed = try? AttributedString(markdown: raw, options: options) {
            return Text(attributed)
        }
        return Text(raw)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 8
        case 2: return fontSize + 5
        case 3: return fontSize + 2
        default: return fontSize + 1
        }
    }
}

enum MarkdownLine: Equatable {
    case heading(level: Int, String)
    case paragraph(String)
    case bullet(indent: Int, String)
    case numbered(indent: Int, number: Int, String)
    case quote(String)
    case rule
    case spacer
}

enum MarkdownLineParser {
    static func parse(_ input: String) -> [MarkdownLine] {
        var result: [MarkdownLine] = []
        let rawLines = input.components(separatedBy: "\n")

        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if case .spacer = result.last {} else if !result.isEmpty {
                    result.append(.spacer)
                }
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                result.append(.rule)
                continue
            }

            // Headings
            if let (level, content) = headingMatch(trimmed) {
                result.append(.heading(level: level, content))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                result.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }

            let indent = indentLevel(of: raw)

            // Bullet list
            if let content = bulletContent(trimmed) {
                result.append(.bullet(indent: indent, content))
                continue
            }

            // Numbered list
            if let (number, content) = numberedContent(trimmed) {
                result.append(.numbered(indent: indent, number: number, content))
                continue
            }

            result.append(.paragraph(trimmed))
        }

        // Trim trailing spacer.
        if case .spacer = result.last { result.removeLast() }
        return result
    }

    private static func headingMatch(_ line: String) -> (Int, String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let content = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return (level, content)
    }

    private static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedContent(_ line: String) -> (Int, String)? {
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits), index < line.endIndex else { return nil }
        guard line[index] == "." || line[index] == ")" else { return nil }
        let after = line.index(after: index)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return (number, String(line[line.index(after: after)...]))
    }

    private static func indentLevel(of raw: String) -> Int {
        var spaces = 0
        for ch in raw {
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 2 }
            else { break }
        }
        return min(spaces / 2, 3)
    }
}
