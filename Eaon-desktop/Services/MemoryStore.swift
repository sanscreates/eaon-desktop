import Foundation

/// What kind of thing a memory is — a durable fact ("works as a teacher in
/// Austin") or a dated happening from the user's life ("had a chess
/// tournament", "math final on Friday"). The split exists because they age
/// differently: a fact stays relevant until it changes; an event matters a
/// lot this week and not much next month. `promptBlock` uses that to keep
/// the injected context feeling like a friend's working memory instead of
/// an ever-growing dossier.
enum MemoryKind: String, Codable {
    case fact
    case event
}

struct MemoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date
    /// Optional so items saved before kinds existed decode fine (Swift's
    /// synthesized Decodable throws on a missing non-optional key — the
    /// exact silent-data-loss trap `ChatMessage.wasColdLoad`'s doc comment
    /// documents from experience). Read through `resolvedKind`.
    var kind: MemoryKind?

    var resolvedKind: MemoryKind { kind ?? .fact }

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), kind: MemoryKind = .fact) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.kind = kind
    }
}

/// Durable, user-visible things Eaon remembers across conversations — the
/// user's own manual entries, plus anything `MemoryExtractor` silently
/// pulled out of a chat (and, with separate consent, out of plugin results
/// or a user-chosen file). Off by default: nothing is stored or sent until
/// the user turns it on in Settings.
@MainActor
@Observable
final class MemoryStore {
    static let shared = MemoryStore()

    /// Storage cap — what can be REMEMBERED. What gets SENT per request is
    /// separately capped by `promptBlock` (facts cap + a recency window on
    /// events), so a long-lived memory can grow without every chat paying
    /// for all of it.
    static let maxMemories = 250
    /// Prompt-side caps: the block must stay a short, skimmable briefing.
    private static let maxPromptFacts = 60
    private static let maxPromptEvents = 15
    /// Events older than this stay stored (and visible in Settings) but
    /// stop riding along in prompts — last month's dentist appointment is
    /// exactly the thing a human would quietly stop bringing up.
    private static let eventPromptWindowDays = 30

    private static let memoriesKey = "eaon_memories"
    private static let enabledKey = "eaon_memory_enabled"
    private static let autoLearnEnabledKey = "eaon_memory_autolearn_enabled"
    private static let pluginLearnEnabledKey = "eaon_memory_plugin_learn_enabled"
    private static let lastAutoLearnKey = "eaon_memory_last_autolearn"

    private(set) var memories: [MemoryItem] = []
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }
    /// Whether a message you send silently triggers `MemoryExtractor` to
    /// look for new facts — separate from `isEnabled`, which only
    /// controls whether facts already saved get used in chats. Turning
    /// this off stops the ongoing background extraction call after every
    /// message while everything already remembered keeps working; it has
    /// no effect on the explicit, one-time "Learn from your existing
    /// chats" backfill, which isn't automatic and stays available either
    /// way. Defaults to true (matching the only behavior this app had
    /// before this setting existed) so adding it doesn't silently change
    /// anything for someone who never touches it.
    var isAutoLearnEnabled: Bool {
        didSet {
            guard isAutoLearnEnabled != oldValue else { return }
            UserDefaults.standard.set(isAutoLearnEnabled, forKey: Self.autoLearnEnabledKey)
        }
    }
    /// Separate, off-by-default consent for learning from what CONNECTED
    /// PLUGINS return in chat (calendar events, issues, documents…). Off
    /// means extraction only ever sees what the user and the model
    /// themselves wrote. Its own toggle — not folded into auto-learn —
    /// because plugin results routinely carry other people's information
    /// and content the user never typed, which deserves an explicit yes.
    var isPluginLearnEnabled: Bool {
        didSet {
            guard isPluginLearnEnabled != oldValue else { return }
            UserDefaults.standard.set(isPluginLearnEnabled, forKey: Self.pluginLearnEnabledKey)
        }
    }
    /// Human-readable outcome of the most recent automatic extraction —
    /// "Learned 2 new things · 3:41 PM", "Nothing new · 3:41 PM", or a
    /// plain-words failure. Exists because the extractor is deliberately
    /// silent in chat, which previously made "working and finding
    /// nothing" indistinguishable from "broken" — the exact complaint
    /// that led to this file's overhaul.
    var lastAutoLearnSummary: String? {
        didSet {
            guard lastAutoLearnSummary != oldValue else { return }
            UserDefaults.standard.set(lastAutoLearnSummary, forKey: Self.lastAutoLearnKey)
        }
    }

    var isFull: Bool { memories.count >= Self.maxMemories }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isAutoLearnEnabled = UserDefaults.standard.object(forKey: Self.autoLearnEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.autoLearnEnabledKey)
        isPluginLearnEnabled = UserDefaults.standard.bool(forKey: Self.pluginLearnEnabledKey)
        lastAutoLearnSummary = UserDefaults.standard.string(forKey: Self.lastAutoLearnKey)
        if let data = UserDefaults.standard.data(forKey: Self.memoriesKey),
           let decoded = try? JSONDecoder().decode([MemoryItem].self, from: data) {
            memories = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Adds extracted items, silently skipping near-duplicates (a plain
    /// case-insensitive containment check, not embeddings: this list is
    /// meant to stay short and human-readable, not grow an entry for every
    /// slight rephrasing of the same fact). Returns how many were actually
    /// added, so callers can report a truthful "learned N" instead of
    /// counting attempts.
    @discardableResult
    func addExtracted(_ items: [(kind: MemoryKind, text: String)]) -> Int {
        var added = 0
        for item in items {
            guard memories.count < Self.maxMemories else { break }
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isDuplicate(of: trimmed) else { continue }
            memories.insert(MemoryItem(text: trimmed, kind: item.kind), at: 0)
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    @discardableResult
    func addManual(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, memories.count < Self.maxMemories, !isDuplicate(of: trimmed) else { return false }
        memories.insert(MemoryItem(text: trimmed), at: 0)
        persist()
        return true
    }

    func remove(_ id: UUID) {
        memories.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        guard !memories.isEmpty else { return }
        memories.removeAll()
        persist()
    }

    /// The system-prompt briefing built from what's remembered — nil when
    /// there's nothing to say. Facts first (capped), then recent events
    /// with the date the user mentioned them, newest first, limited to the
    /// last `eventPromptWindowDays`. Ends with guidance to USE the memory
    /// like a person would — follow up on how things went, connect topics —
    /// rather than recite it; the whole point of the feature is a
    /// conversation that feels like it's with someone who knows you.
    /// `now` is injectable for tests; production callers pass nothing.
    func promptBlock(now: Date = Date()) -> String? {
        guard isEnabled, !memories.isEmpty else { return nil }

        let facts = memories.filter { $0.resolvedKind == .fact }.prefix(Self.maxPromptFacts)
        let windowStart = now.addingTimeInterval(-TimeInterval(Self.eventPromptWindowDays) * 86_400)
        let events = memories
            .filter { $0.resolvedKind == .event && $0.createdAt >= windowStart && $0.createdAt <= now }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.maxPromptEvents)

        guard !facts.isEmpty || !events.isEmpty else { return nil }

        var sections: [String] = [
            "What you know about this user from earlier conversations. Weave it in naturally when it's relevant — follow up on how something went, connect new topics to what you know — without reciting this list back or claiming to remember anything not on it."
        ]
        if !facts.isEmpty {
            sections.append("Facts:\n" + facts.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !events.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM d"
            let lines = events.map { "- \(formatter.string(from: $0.createdAt)): \($0.text)" }
            sections.append("Recent happenings in their life (dated by when they mentioned it, newest first):\n" + lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private func isDuplicate(of fact: String) -> Bool {
        memories.contains {
            $0.text.localizedCaseInsensitiveContains(fact) || fact.localizedCaseInsensitiveContains($0.text)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(memories) else { return }
        UserDefaults.standard.set(data, forKey: Self.memoriesKey)
    }
}

/// Pure parsing for extractor replies — separated from `MemoryExtractor`
/// (which drags in the whole networking stack) so the riskiest logic here
/// stays compilable and testable standalone, the same layering reason
/// `WorkspaceParser` is separate from the agent loop.
enum MemoryParsing {
    /// Matches `WorkspaceParser.strippedOfThinking`'s behavior for the one
    /// case that matters here: a reasoning model wrapping its reply in a
    /// `<think>…</think>` span whose prose can contain stray `[`
    /// characters — which used to send `extractJSONArray` hunting inside
    /// the reasoning and coming back with garbage (one of the reasons
    /// extraction never visibly worked). Duplicated as a private tiny
    /// regex rather than importing WorkspaceParser, to keep this file's
    /// standalone-compile property.
    private static let thinkSpanRegex = try! NSRegularExpression(
        pattern: "<think>[\\s\\S]*?</think>|<thinking>[\\s\\S]*?</thinking>",
        options: [.caseInsensitive]
    )

    /// Parses the extractor's reply into memory items, tolerantly:
    /// - the requested shape: `[{"kind": "fact"|"event", "text": "…"}]`
    /// - the legacy/lazy shape: `["…", "…"]` (treated as facts)
    /// - a mix of both in one array
    /// - any of the above buried in prose or a reasoning span
    /// Unknown kinds default to `fact`; blank/oversized texts are dropped.
    static func parseItems(from raw: String) -> [(kind: MemoryKind, text: String)] {
        let range = NSRange(raw.startIndex..., in: raw)
        let stripped = thinkSpanRegex.stringByReplacingMatches(in: raw, range: range, withTemplate: "\n")
        guard let jsonText = extractJSONArray(from: stripped),
              let data = jsonText.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }

        var items: [(MemoryKind, String)] = []
        for element in array {
            if let text = element as? String {
                items.append((.fact, text))
            } else if let object = element as? [String: Any], let text = object["text"] as? String {
                let kind = (object["kind"] as? String).flatMap(MemoryKind.init(rawValue:)) ?? .fact
                items.append((kind, text))
            }
        }
        return items
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty && $0.1.count < 300 }
    }

    /// Finds a JSON array's exact substring anywhere in `text` — tracking
    /// bracket depth and skipping over quoted-string contents (so a
    /// literal "[" or "]" inside a fact string, or in trailing prose,
    /// doesn't throw off the boundary) — rather than requiring the whole
    /// reply to be pure JSON. Models reliably ignore "reply with ONLY
    /// JSON, no commentary" — especially weaker/local ones — so this has
    /// to tolerate a preamble ("Sure, here's what I found:") or a
    /// trailing note instead of silently discarding real facts.
    static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if isEscaped {
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "[" {
                    depth += 1
                } else if char == "]" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
