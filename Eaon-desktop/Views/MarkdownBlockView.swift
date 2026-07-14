import SwiftUI

/// Renders a plain-markdown text segment (no fenced code — that is handled
/// upstream) into ChatGPT-style typographic blocks: headings, paragraphs,
/// bullet / numbered lists, blockquotes, tables, and horizontal rules.
/// Inline emphasis, `code`, and [links](…) are rendered via AttributedString.
struct MarkdownBlockView: View {
    @Environment(\.themeColors) private var colors
    let text: String

    private var fontSize: CGFloat { AppearanceSettings.shared.fontSize.messageFontSize }

    /// Memoized — this re-parsed the whole segment on every body
    /// evaluation, which during streaming meant every typewriter tick.
    /// Streaming segments still churn the cache (their text grows every
    /// tick, so each key is new), but FIFO eviction handles that; the win
    /// is finished messages, whose re-renders and scroll-ins become
    /// lookups.
    private var lines: [MarkdownLine] {
        RenderCache.shared.value("md|\(text)") {
            MarkdownLineParser.parse(text)
        }
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

        case .table(let headers, let alignments, let rows):
            table(headers: headers, alignments: alignments, rows: rows)
                .padding(.vertical, 8)

        case .rule:
            Rectangle()
                .fill(colors.borderSubtle)
                .frame(height: 1)
                .padding(.vertical, 12)

        case .spacer:
            Color.clear.frame(height: 6)
        }
    }

    // MARK: - Table

    private func table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]]) -> some View {
        Grid(alignment: .top, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    tableCell(header, alignment: alignment(at: index, in: alignments), isHeader: true)
                }
            }
            Divider().overlay(colors.borderMedium).gridCellColumns(max(headers.count, 1))

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(headers.indices), id: \.self) { colIndex in
                        tableCell(colIndex < row.count ? row[colIndex] : "", alignment: alignment(at: colIndex, in: alignments), isHeader: false)
                    }
                }
                if rowIndex != rows.count - 1 {
                    Divider().overlay(colors.borderSubtle).gridCellColumns(max(headers.count, 1))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colors.backgroundSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableCell(_ text: String, alignment: MarkdownTableAlignment, isHeader: Bool) -> some View {
        inline(text)
            .font(AppFont.sans(fontSize - 1, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? colors.textPrimary : colors.textSecondary)
            .multilineTextAlignment(alignment.textAlignment)
            .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .textSelection(.enabled)
    }

    private func alignment(at index: Int, in alignments: [MarkdownTableAlignment]) -> MarkdownTableAlignment {
        index < alignments.count ? alignments[index] : .leading
    }

    private func inline(_ raw: String) -> Text {
        // `AttributedString(markdown:)` is Foundation's full markdown
        // parser — the priciest single call in this view, and it ran once
        // per paragraph/bullet/table-cell per render (a 50-line reply
        // meant ~50 parses per tick while streaming). Memoized by the raw
        // string: identical inline segments across all messages share one
        // parse.
        let attributed = RenderCache.shared.value("mdinline|\(raw)") { () -> AttributedString? in
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try? AttributedString(markdown: raw, options: options)
        }
        if let attributed { return Text(attributed) }
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

enum MarkdownTableAlignment: Equatable {
    case leading, center, trailing

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

enum MarkdownLine: Equatable {
    case heading(level: Int, String)
    case paragraph(String)
    case bullet(indent: Int, String)
    case numbered(indent: Int, number: Int, String)
    case quote(String)
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case rule
    case spacer
}

enum MarkdownLineParser {
    static func parse(_ input: String) -> [MarkdownLine] {
        var result: [MarkdownLine] = []
        let rawLines = input.components(separatedBy: "\n")
        var i = 0

        while i < rawLines.count {
            let raw = rawLines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if case .spacer = result.last {} else if !result.isEmpty {
                    result.append(.spacer)
                }
                i += 1
                continue
            }

            // Table: a row containing "|" immediately followed by a valid
            // "| --- | --- |"-style separator row of the same width.
            if trimmed.contains("|"), i + 1 < rawLines.count {
                let headerCells = tableCells(trimmed)
                let separatorCells = tableCells(rawLines[i + 1].trimmingCharacters(in: .whitespaces))
                if headerCells.count >= 2, headerCells.count == separatorCells.count, isTableSeparatorRow(separatorCells) {
                    let alignments = separatorCells.map(tableAlignment(for:))
                    var rows: [[String]] = []
                    var j = i + 2
                    while j < rawLines.count {
                        let rowTrimmed = rawLines[j].trimmingCharacters(in: .whitespaces)
                        guard !rowTrimmed.isEmpty, rowTrimmed.contains("|") else { break }
                        rows.append(tableCells(rowTrimmed))
                        j += 1
                    }
                    result.append(.table(headers: headerCells, alignments: alignments, rows: rows))
                    i = j
                    continue
                }
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                result.append(.rule)
                i += 1
                continue
            }

            // Headings
            if let (level, content) = headingMatch(trimmed) {
                result.append(.heading(level: level, content))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                result.append(.quote(String(trimmed.dropFirst(2))))
                i += 1
                continue
            }

            let indent = indentLevel(of: raw)

            // Bullet list
            if let content = bulletContent(trimmed) {
                result.append(.bullet(indent: indent, content))
                i += 1
                continue
            }

            // Numbered list
            if let (number, content) = numberedContent(trimmed) {
                result.append(.numbered(indent: indent, number: number, content))
                i += 1
                continue
            }

            result.append(.paragraph(trimmed))
            i += 1
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

    // MARK: - Table helpers

    private static func tableCells(_ line: String) -> [String] {
        var content = line
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparatorRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var inner = Substring(cell)
            if inner.first == ":" { inner.removeFirst() }
            if inner.last == ":" { inner.removeLast() }
            return !inner.isEmpty && inner.allSatisfy { $0 == "-" }
        }
    }

    private static func tableAlignment(for cell: String) -> MarkdownTableAlignment {
        let leading = cell.hasPrefix(":")
        let trailing = cell.hasSuffix(":")
        if leading && trailing { return .center }
        if trailing { return .trailing }
        return .leading
    }
}
