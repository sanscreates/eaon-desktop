import Foundation
import SwiftUI

/// One page-snippet result from `WebSearchService.search`.
struct WebSearchResult: Equatable {
    let url: String
    let snippet: String
}

enum WebSearchServiceError: LocalizedError {
    case emptyQuery
    case decoding
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery: return "Empty search query."
        case .decoding: return "The search service returned an unexpected response."
        case .apiError(let message): return message
        }
    }
}

/// Live web search backed by MIKLIUM's free, keyless Search API
/// (github.com/MIKLIUM-Team/MIKLIUM) — an independent, third-party service,
/// not Aqua's own. Its `results` are short search-engine snippets, not full
/// page scrapes: `maxLargeSnippets: 0` deliberately skips MIKLIUM's
/// full-text-scrape mode, which fetches and parses arbitrary third-party
/// pages and can add many extra seconds per query — short snippets keep a
/// search call fast and predictable enough to fire mid-conversation without
/// the agent loop stalling.
enum WebSearchService {
    private static let endpoint = URL(string: "https://miklium.vercel.app/api/search")!

    static func search(query: String) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchServiceError.emptyQuery }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "search": [trimmed],
            "type": "default",
            "maxSmallSnippets": 8,
            "maxLargeSnippets": 0,
        ])

        let (data, _) = try await AppHTTP.session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchServiceError.decoding
        }
        // MIKLIUM reports failure (including the "zero results" case) via a
        // 4xx/404 HTTP status, but always with the same {success, error}
        // JSON body as a success response — so `success` alone is enough to
        // branch on, no need to also inspect the HTTP status.
        guard json["success"] as? Bool == true, let rawResults = json["results"] as? [[String: Any]] else {
            throw WebSearchServiceError.apiError((json["error"] as? String) ?? "No results found.")
        }
        return rawResults.compactMap { entry in
            guard let url = entry["url"] as? String, let snippet = entry["snippet"] as? String else { return nil }
            return WebSearchResult(url: url, snippet: snippet)
        }
    }

    /// Numbered so the model can cite "result 2" unambiguously, and so a
    /// reader skimming the collapsed tool-results card can tell how many
    /// sources actually came back.
    static func formattedResultsForModel(_ results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "No results found." }
        return results.enumerated()
            .map { index, result in "\(index + 1). \(result.url)\n   \(result.snippet)" }
            .joined(separator: "\n\n")
    }
}

/// The `eaon:search` fence's native-tool-calling mirror and its
/// system-prompt teaching text — see `NativeToolCalling.swift`'s header
/// comment for why both channels exist side by side.
enum WebSearchTool {
    /// Deliberately snake_case with a single underscore: `ToolCallAccumulator.
    /// fencedBlocks` matches this name literally, before it ever tries the
    /// `<server>__<tool>` MCP namespacing convention (which splits on a
    /// *double* underscore), so a real MCP tool can never collide with it.
    static let nativeFunctionName = "web_search"

    static let nativeDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": nativeFunctionName,
            "description": "Search the live web for current, real-world information that may have changed since your training, or that you can't be sure of: recent news and events, today's prices/scores/weather/exchange rates, the latest version or status of something, or any fact you'd otherwise be guessing at. Returns short snippets from real webpages with their source URLs. Do NOT use it for things you already know or can work out yourself (general knowledge, explanations, math, coding, writing, reasoning, definitions), and do NOT use it for the current date or time — you are given those directly. Only search when the question genuinely needs up-to-date external information.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "A focused search-engine query — a few keywords, not a full sentence question.",
                    ],
                ],
                "required": ["query"],
            ],
        ],
    ]

    /// Unlike `MCPConnectionStore.agentInstructionBlock`, this is not
    /// gated on any "connection" — there's nothing to connect, so it's
    /// either on (see `WebSearchStore.isEnabled`) or it doesn't exist as
    /// far as the model is concerned. See that store's doc comment for why
    /// this matters: an instruction the model is never actually sent is
    /// functionally dead, the fate of this app's older, unsent coding-agent
    /// prompt.
    ///
    /// Leads with the real current date/time (the device clock) for two
    /// reasons: it answers "what's today / what time is it" from context
    /// with no search at all — search snippets can't reliably give the
    /// local wall-clock time anyway — and it's the anchor the model needs
    /// to reason about what actually falls *after* its training cutoff and
    /// therefore genuinely warrants a search. `now` is a parameter (rather
    /// than reading the clock inside) so the block is deterministic to test.
    static func agentInstructionBlock(now: Date = Date()) -> String {
        """
        The current date and time is \(contextDateFormatter.string(from: now)). Use this directly for anything about today, "now", or the current date/time — never search the web for it.

        You also have live web search — real internet search, not just what you already know. Use it ONLY when a question genuinely needs current, real-world information you can't be sure of:
        - Recent or breaking news, current events, an unfolding situation
        - Today's prices, scores, weather, exchange rates, or similar live figures
        - The latest version, release, result, or status of something
        - Any fact that may have changed since your training, or that you'd otherwise be guessing at

        Do NOT search for things you already know or can work out yourself — general knowledge, explanations, math, coding, writing, reasoning, definitions — or for the current date/time given above. Never search speculatively or "just to check."

        To search, use a fenced block with the query as JSON:

        ```eaon:search
        {"query": "focused search keywords"}
        ```

        Always close the fence with ``` on its own line. After your reply, any eaon:search calls run and their results (page snippets with source URLs) come back to you in a message beginning "[Tool results". You then continue — this loops until you reply with no tool calls. When you use what search returned, cite the source URLs. Once you can answer, reply in plain language — never end your turn on a raw tool call.
        """
    }

    /// "Friday, July 10, 2026 at 6:57 PM PDT" — pinned to en_US so the
    /// prompt text stays English regardless of the Mac's locale, but left
    /// on the device's own time zone so the time is actually the user's.
    private static let contextDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        return formatter
    }()
}

/// Whether the model is allowed to use `WebSearchTool` at all — on by
/// default, since a user who hasn't touched this setting is exactly the
/// user who asked Eaon to answer time-sensitive questions in the first
/// place. Off means the teaching block and native tool definition are
/// never sent, and (belt-and-suspenders, in case a model emits the fence
/// unprompted) any `eaon:search` call is refused at execution time too —
/// see `ChatViewModel.executeAgentTools`.
@MainActor
@Observable
final class WebSearchStore {
    static let shared = WebSearchStore()

    private static let enabledKey = "eaon_web_search_enabled"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.enabledKey)
    }
}
