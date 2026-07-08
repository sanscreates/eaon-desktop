import Foundation

enum MessageBlock: Equatable {
    case text(String)
    case code(language: String?, content: String)
}

enum MessageContentParser {
    static func parse(_ input: String) -> [MessageBlock] {
        guard input.contains("```") else {
            return input.isEmpty ? [] : [.text(input)]
        }

        var blocks: [MessageBlock] = []
        let segments = input.components(separatedBy: "```")

        for (index, segment) in segments.enumerated() {
            if index == 0 {
                if !segment.isEmpty {
                    blocks.append(.text(segment))
                }
                continue
            }

            if index.isMultiple(of: 2) {
                if !segment.isEmpty {
                    blocks.append(.text(segment))
                }
            } else {
                let (language, code) = splitCodeFenceContent(segment)
                blocks.append(.code(language: language, content: code))
            }
        }

        return blocks
    }

    private static func splitCodeFenceContent(_ segment: String) -> (String?, String) {
        guard let newlineIndex = segment.firstIndex(of: "\n") else {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return (nil, "")
            }
            return (trimmed, "")
        }

        let firstLine = String(segment[..<newlineIndex]).trimmingCharacters(in: .whitespaces)
        let codeStart = segment.index(after: newlineIndex)
        let code = String(segment[codeStart...])
        let language = firstLine.isEmpty ? nil : firstLine
        return (language, code)
    }
}
