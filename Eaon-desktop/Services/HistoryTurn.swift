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

    /// Trims history to fit a local server's real context window. Unlike
    /// cloud providers (100K+ windows, own truncation), a spawned
    /// llama-server has a hard, small window: a request over it is an HTTP
    /// 400 `exceed_context_size_error` — verified live — which surfaced to
    /// the user as a raw error the moment a chat grew past the window
    /// ("small models crash out on long chats"). Policy: keep the system
    /// turn (the app's operating instructions) and the newest turns; drop
    /// whole oldest turns first; if the survivors alone still overflow
    /// (giant pasted message, or a huge system stack in Agent mode),
    /// truncate the biggest one's middle. ~4 chars/token, the same estimate
    /// `ContextWindowEstimator` uses, with real headroom reserved for the
    /// reply so "fits" means the whole request, not just the prompt.
    func trimmedToFit(contextTokens: Int, replyHeadroomTokens: Int = 1_024) -> [HistoryTurn] {
        let budgetTokens = contextTokens - replyHeadroomTokens
        guard budgetTokens > 0 else { return self }
        func tokens(_ turn: HistoryTurn) -> Int { turn.content.count / 4 + 8 }
        guard map(tokens).reduce(0, +) > budgetTokens else { return self }

        let systemTurns = filter { $0.role == "system" }
        var conversation = filter { $0.role != "system" }
        var kept: [HistoryTurn] = []
        var used = systemTurns.map(tokens).reduce(0, +)
        // Newest first, so the current question always survives ahead of
        // old context.
        for turn in conversation.reversed() {
            let cost = tokens(turn)
            guard used + cost <= budgetTokens else { break }
            kept.insert(turn, at: 0)
            used += cost
        }

        // Survivors alone still over budget → nothing droppable is left;
        // cut the single biggest turn's middle instead of failing. The
        // newest conversation turn is force-kept even here — a request
        // with no user turn at all is a guaranteed template error.
        if kept.isEmpty, let newest = conversation.last {
            kept = [newest]
        }
        // Dropping oldest turns can leave an assistant turn first — the
        // exact strict-template violation `flattenedForStrictChatTemplates`
        // just fixed. Re-enforce user-first on the survivors.
        while let first = kept.first, first.role != "user", kept.count > 1 {
            kept.removeFirst()
        }
        conversation = systemTurns + kept
        let total = conversation.map(tokens).reduce(0, +)
        if total > budgetTokens,
           let bigIndex = conversation.indices.max(by: { tokens(conversation[$0]) < tokens(conversation[$1]) }) {
            let overshootChars = (total - budgetTokens) * 4
            let content = conversation[bigIndex].content
            let keepChars = Swift.max(400, content.count - overshootChars - 64)
            if content.count > keepChars {
                let head = content.prefix(keepChars / 2)
                let tail = content.suffix(keepChars / 2)
                conversation[bigIndex] = HistoryTurn(
                    role: conversation[bigIndex].role,
                    content: head + "\n\n[… trimmed to fit this model's context window …]\n\n" + tail,
                    images: conversation[bigIndex].images
                )
            }
        }
        return conversation
    }
}
