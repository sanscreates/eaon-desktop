import Foundation

/// One content block of an MCP tool result. MCP defines more block types
/// (image/audio/resource) — only text is rendered back to the model today,
/// since that's what every tool this app talks to actually returns for
/// now; `.other` keeps anything else from being silently dropped.
enum MCPContentBlock {
    case text(String)
    case other(type: String)
}

struct MCPTool {
    let name: String
    let description: String?
    let inputSchema: [String: Any]

    struct Parameter {
        let name: String
        let type: String
        let isRequired: Bool
        /// JSON Schema `enum` values, when the parameter only accepts a
        /// fixed set — the single highest-value fact for a model shaping
        /// arguments, since a wrong enum value fails where a free-form
        /// string would have succeeded.
        let enumValues: [String]
        let description: String?
    }

    /// The tool's parameters, required ones first — so anything that
    /// truncates this list from the tail drops optional parameters, never
    /// one the call can't succeed without.
    var parameters: [Parameter] {
        guard let properties = inputSchema["properties"] as? [String: Any] else { return [] }
        let required = Set(inputSchema["required"] as? [String] ?? [])
        let orderedKeys = properties.keys.sorted { a, b in
            let ra = required.contains(a), rb = required.contains(b)
            if ra != rb { return ra }
            return a < b
        }
        return orderedKeys.map { key in
            let prop = properties[key] as? [String: Any] ?? [:]
            return Parameter(
                name: key,
                type: prop["type"] as? String ?? "any",
                isRequired: required.contains(key),
                enumValues: (prop["enum"] as? [Any])?.map { "\($0)" } ?? [],
                description: prop["description"] as? String
            )
        }
    }

    var requiredParameterNames: [String] {
        parameters.filter(\.isRequired).map(\.name)
    }

    /// The full per-parameter spec, one line each with type/required/
    /// allowed values/description. Deliberately NOT sent up front for
    /// every tool (that cost sank smaller models — see
    /// `MCPConnectionStore.maxCatalogCharacters`); it's fed back to the
    /// model exactly when a call fails, so the retry is informed.
    var detailedSpec: String {
        let params = parameters
        guard !params.isEmpty else { return "\(name) takes no arguments — use {} as the body." }
        let lines = params.map { p -> String in
            var line = "  \(p.name) (\(p.type)\(p.isRequired ? ", required" : ""))"
            if !p.enumValues.isEmpty {
                line += " — one of: \(p.enumValues.prefix(12).joined(separator: " | "))"
            }
            if let d = p.description?.replacingOccurrences(of: "\n", with: " "), !d.isEmpty {
                line += " — \(d.count > 140 ? String(d.prefix(140)) + "…" : d)"
            }
            return line
        }
        return "Parameters for \(name):\n" + lines.joined(separator: "\n")
    }

    /// A valid example body covering every required parameter with a
    /// type-appropriate placeholder (first enum value when one exists) —
    /// used to build the one worked example in the system prompt, since
    /// models imitate a concrete example far more reliably than they
    /// follow an abstract syntax description.
    var exampleArgumentsJSON: String {
        let req = parameters.filter(\.isRequired)
        guard !req.isEmpty else { return "{}" }
        let fields = req.map { p -> String in
            let value: String
            if let first = p.enumValues.first {
                value = "\"\(first)\""
            } else {
                switch p.type {
                case "number", "integer": value = "1"
                case "boolean": value = "true"
                case "array": value = "[]"
                case "object": value = "{}"
                default: value = "\"example\""
                }
            }
            return "\"\(p.name)\": \(value)"
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }
}

struct MCPToolResult {
    let content: [MCPContentBlock]
    /// True when the *tool* failed (e.g. "repo not found") — still a
    /// successful RPC call, per spec. Distinct from a thrown `MCPError`,
    /// which means the call itself (transport, auth, protocol) failed.
    let isError: Bool

    var textSummary: String {
        let text = content.compactMap { block -> String? in
            if case .text(let s) = block { return s }
            return nil
        }.joined(separator: "\n")
        return text.isEmpty ? "(no text content returned)" : text
    }
}

enum MCPError: LocalizedError {
    case httpError(Int)
    case rpcError(code: Int, message: String)
    case malformedResponse
    case notConnected

    var errorDescription: String? {
        switch self {
        case .httpError(401), .httpError(403):
            return "That token doesn't look valid — check it has the right scopes and try again."
        case .httpError(let code):
            return "The server returned an error (HTTP \(code)). Try again in a moment."
        case .rpcError(_, let message):
            return message
        case .malformedResponse:
            return "Got a response that didn't look like a valid MCP reply."
        case .notConnected:
            return "Not connected yet."
        }
    }
}

/// A minimal MCP (Model Context Protocol) client speaking the Streamable
/// HTTP transport directly — no SDK, matching this app's zero-dependency
/// design. One instance per connected server; holds the session id the
/// server may assign during `initialize`, per the spec (2025-06-18,
/// verified against modelcontextprotocol.io/specification). Generic
/// across servers — see `MCPCatalog` for the specific, individually
/// verified endpoint/auth details of each service this app connects to.
actor MCPClient {
    private static let protocolVersion = "2025-06-18"

    private let endpoint: URL
    private let token: String
    /// The `Authorization` header's scheme word. Every server surveyed
    /// puts the token in `Authorization`, but not all agree on the
    /// scheme: GitHub/Render/Neon/etc. use the standard "Bearer", Sentry
    /// requires the nonstandard "Sentry-Bearer", Semrush requires
    /// "Apikey". Defaults to "Bearer" since that covers most servers.
    private let authScheme: String
    /// Extra headers sent with every request — e.g. GitHub's own
    /// `X-MCP-Toolsets` extension for scoping down which tools a remote
    /// server exposes. Not part of the MCP spec itself, so this stays a
    /// generic passthrough rather than protocol-level knowledge.
    private let extraHeaders: [String: String]
    private var nextId = 1
    private var sessionId: String?
    private var didInitialize = false

    init(endpoint: URL, token: String, authScheme: String = "Bearer", extraHeaders: [String: String] = [:]) {
        self.endpoint = endpoint
        self.token = token
        self.authScheme = authScheme
        self.extraHeaders = extraHeaders
    }

    /// Handshake: `initialize`, then the required (reply-less)
    /// `notifications/initialized`. Must complete before any `tools/*`
    /// call — the spec is explicit that servers may reject calls made
    /// before this notification arrives.
    func connect() async throws {
        let params: [String: Any] = [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Eaon", "version": AppVersion.current],
        ]
        _ = try await send(method: "initialize", params: params, expectsReply: true)
        didInitialize = true
        _ = try await send(method: "notifications/initialized", params: nil, expectsReply: false)
    }

    func listTools() async throws -> [MCPTool] {
        guard didInitialize else { throw MCPError.notConnected }
        var tools: [MCPTool] = []
        var cursor: String?

        // Paginate fully rather than exposing cursors upward — every
        // caller today just wants "everything this server offers."
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await send(method: "tools/list", params: params, expectsReply: true) ?? [:]
            let entries = result["tools"] as? [[String: Any]] ?? []
            tools += entries.compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                return MCPTool(
                    name: name,
                    description: entry["description"] as? String,
                    inputSchema: entry["inputSchema"] as? [String: Any] ?? [:]
                )
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil

        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        guard didInitialize else { throw MCPError.notConnected }
        let params: [String: Any] = ["name": name, "arguments": arguments]
        let result = try await send(method: "tools/call", params: params, expectsReply: true) ?? [:]

        let isError = result["isError"] as? Bool ?? false
        let entries = result["content"] as? [[String: Any]] ?? []
        let blocks: [MCPContentBlock] = entries.map { block in
            let type = block["type"] as? String ?? "unknown"
            if type == "text", let text = block["text"] as? String {
                return .text(text)
            }
            return .other(type: type)
        }
        return MCPToolResult(content: blocks, isError: isError)
    }

    // MARK: - Wire

    @discardableResult
    private func send(method: String, params: [String: Any]?, expectsReply: Bool) async throws -> [String: Any]? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // Both values, one header — the spec's literal requirement, since
        // the server chooses per-call whether to answer as plain JSON or
        // as an SSE stream and the client MUST accept either.
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("\(authScheme) \(token)", forHTTPHeaderField: "Authorization")
        for (field, value) in extraHeaders {
            request.addValue(value, forHTTPHeaderField: field)
        }
        // MUST accompany every request *after* initialize — not on
        // initialize itself, since that's what negotiates the version.
        if didInitialize {
            request.addValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionId {
            request.addValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }

        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { body["params"] = params }
        let requestId = nextId
        if expectsReply {
            body["id"] = requestId
            nextId += 1
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AppHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.malformedResponse }

        // The server may assign a session on any response — capture it
        // whenever present rather than only after initialize, since the
        // spec doesn't pin exactly when it first appears.
        if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? http.value(forHTTPHeaderField: "MCP-Session-Id") {
            sessionId = newSession
        }

        guard (200...299).contains(http.statusCode) else { throw MCPError.httpError(http.statusCode) }
        guard expectsReply else { return nil }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let payload = try Self.extractPayload(data: data, contentType: contentType, matchingId: requestId)
        if let error = payload["error"] as? [String: Any] {
            throw MCPError.rpcError(
                code: error["code"] as? Int ?? 0,
                message: error["message"] as? String ?? "Unknown MCP error"
            )
        }
        return payload["result"] as? [String: Any] ?? [:]
    }

    /// The server may answer as one plain JSON object, or as an SSE
    /// stream of `data: {...}` records — the spec leaves the choice to
    /// the server. There's no mandated `event:` field to key off, so this
    /// parses leniently: take the first SSE record whose `id` matches
    /// this request, ignoring anything else in the stream.
    private static func extractPayload(data: Data, contentType: String, matchingId: Int) throws -> [String: Any] {
        if contentType.contains("text/event-stream") {
            guard let text = String(data: data, encoding: .utf8) else { throw MCPError.malformedResponse }
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let jsonText = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                guard let jsonData = jsonText.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      (obj["id"] as? Int) == matchingId else { continue }
                return obj
            }
            throw MCPError.malformedResponse
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.malformedResponse
        }
        return obj
    }
}
