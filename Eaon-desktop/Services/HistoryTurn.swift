import Foundation

/// One turn in a request's message history sent to any provider. `images`
/// is empty for every system/tool-result/memory turn and any user turn
/// without an attachment the active model can actually see — only when
/// it's non-empty does a completion path build a real multi-part vision
/// payload instead of plain text.
struct HistoryTurn {
    let role: String
    let content: String
    var images: [HistoryImage]

    init(role: String, content: String, images: [HistoryImage] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

struct HistoryImage: Equatable {
    let base64: String
    let mimeType: String
}

extension HistoryTurn {
    /// OpenAI-compatible `{role, content}` shape — content is a plain
    /// string when there's no image, or a content-parts array when there
    /// is. Every OpenAI-compatible endpoint (including Aqua's own) accepts
    /// either shape.
    var openAICompatibleJSON: [String: Any] {
        guard !images.isEmpty else { return ["role": role, "content": content] }
        var parts: [[String: Any]] = []
        if !content.isEmpty {
            parts.append(["type": "text", "text": content])
        }
        for image in images {
            parts.append(["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"]])
        }
        return ["role": role, "content": parts]
    }
}

extension Array where Element == HistoryTurn {
    /// Local llama.cpp/MLX servers render the model's own EMBEDDED chat
    /// template, and many of those templates (the Gemma family most
    /// famously) hard-`raise_exception` unless the history is exactly: at
    /// most one leading system turn, then strictly alternating
    /// user/assistant starting with user. Eaon's natural history is richer
    /// than that — several separate system blocks (custom instructions,
    /// memory, mode teaching, web search), tool results riding as extra
    /// "user" turns that can land back-to-back with the user's own
    /// message, and reasoning-only assistant turns whose content strips to
    /// empty — and a strict template 500s the WHOLE request over any of it
    /// before a single token is generated. Seen live: `Jinja Exception:
    /// Conversation roles must alternate user/assistant/...` from a
    /// Gemma-based GGUF. Applied on the LOCAL path only; cloud providers
    /// accept the richer shape and keep the finer-grained turns.
    ///
    /// Rules, in order:
    /// 1. Every system turn (wherever it appeared) merges into ONE leading
    ///    system turn, original order preserved. Single-leading-system is
    ///    the one shape these templates make an allowance for.
    /// 2. Turns that are empty after trimming and carry no images are
    ///    dropped — they add nothing and break alternation counting.
    /// 3. App-generated assistant turns BEFORE the first user turn (error
    ///    notices like "add your API key") are dropped: user-first is a
    ///    hard template requirement, and a pre-conversation notice isn't
    ///    context the model needs.
    /// 4. Consecutive same-role turns coalesce into one (contents joined,
    ///    images concatenated).
    var flattenedForStrictChatTemplates: [HistoryTurn] {
        var systemContents: [String] = []
        var conversation: [HistoryTurn] = []
        for turn in self {
            let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if turn.role == "system" {
                if !trimmed.isEmpty { systemContents.append(turn.content) }
            } else if !trimmed.isEmpty || !turn.images.isEmpty {
                conversation.append(turn)
            }
        }

        while let first = conversation.first, first.role != "user" {
            conversation.removeFirst()
        }

        var coalesced: [HistoryTurn] = []
        for turn in conversation {
            if let last = coalesced.last, last.role == turn.role {
                let pieces = [last.content, turn.content]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                coalesced[coalesced.count - 1] = HistoryTurn(
                    role: last.role,
                    content: pieces.joined(separator: "\n\n"),
                    images: last.images + turn.images
                )
            } else {
                coalesced.append(turn)
            }
        }

        guard !systemContents.isEmpty else { return coalesced }
        return [HistoryTurn(role: "system", content: systemContents.joined(separator: "\n\n"))] + coalesced
    }
}
