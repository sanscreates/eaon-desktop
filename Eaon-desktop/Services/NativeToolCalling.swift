import Foundation

/// Native (API-level) tool calling — the `tools` request parameter and
/// `tool_calls` response field of OpenAI-compatible chat APIs.
///
/// This is the mechanism hosted models are actually trained on, which is
/// why ChatGPT/Claude-style tool use feels reliable there: the model emits
/// a structured call, not imitated markup. Eaon's fenced `eaon:mcp` markup
/// predates this and stays as the fallback channel (providers/models
/// without native support, and the Anthropic/Gemini wire formats) — so
/// native calls are translated INTO that same fence syntax on arrival,
/// and everything downstream (chips, per-call confirmation, execution,
/// history) is one shared pipeline regardless of which channel the model
/// used.
struct NativeToolConfig {
    /// The request's `tools` array — full JSON Schemas passed through
    /// verbatim, since the provider-side generation is schema-guided and
    /// lossy summarization is exactly what made markup calling flaky.
    let tools: [[String: Any]]
    /// Namespaced name → (server id, tool name). The reverse of the
    /// namespacing applied when building `tools`, used to translate the
    /// model's calls back.
    let nameMap: [String: (server: String, tool: String)]
}

extension MCPConnectionStore {
    /// Nil when nothing is connected — callers attach `tools` only when
    /// there's something to call.
    var nativeToolConfig: NativeToolConfig? {
        let servers = connectedServers.filter { !tools(for: $0.id).isEmpty }
        guard !servers.isEmpty else { return nil }

        var definitions: [[String: Any]] = []
        var nameMap: [String: (server: String, tool: String)] = [:]
        for server in servers {
            for tool in tools(for: server.id) {
                let namespaced = Self.namespacedToolName(server: server.id, tool: tool.name)
                // First definition wins on a (pathological) post-truncation
                // collision — better one reachable tool than two broken ones.
                guard nameMap[namespaced] == nil else { continue }
                nameMap[namespaced] = (server.id, tool.name)

                var function: [String: Any] = ["name": namespaced]
                if let description = tool.description, !description.isEmpty {
                    function["description"] = String(description.prefix(1024))
                }
                function["parameters"] = tool.inputSchema.isEmpty
                    ? ["type": "object", "properties": [String: Any]()]
                    : tool.inputSchema
                definitions.append(["type": "function", "function": function])
            }
        }
        return NativeToolConfig(tools: definitions, nameMap: nameMap)
    }

    /// `<serverId>__<toolName>`, restricted to the `[A-Za-z0-9_-]{1,64}`
    /// charset OpenAI-compatible APIs require of function names. Pure
    /// string work — `nonisolated` so non-MainActor code (the streaming
    /// layer, tests) can use it directly.
    nonisolated static func namespacedToolName(server: String, tool: String) -> String {
        let raw = "\(server)__\(tool)"
        let sanitized = raw.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "_" || ch == "-" ? ch : "_"
        }
        return String(String(sanitized).prefix(64))
    }
}

/// Reassembles the model's tool calls from an OpenAI-compatible stream,
/// where one call arrives as many `delta.tool_calls` fragments (the
/// `function.arguments` JSON is split across chunks and must be
/// concatenated per call index).
struct ToolCallAccumulator {
    private struct Partial {
        var name = ""
        var arguments = ""
    }

    private var partials: [Int: Partial] = [:]

    var isEmpty: Bool { partials.isEmpty }

    /// Feed one streaming `delta` object.
    mutating func ingest(delta: [String: Any]) {
        guard let calls = delta["tool_calls"] as? [[String: Any]] else { return }
        for call in calls {
            let index = call["index"] as? Int ?? 0
            var partial = partials[index] ?? Partial()
            if let function = call["function"] as? [String: Any] {
                if let name = function["name"] as? String { partial.name += name }
                if let args = function["arguments"] as? String { partial.arguments += args }
            }
            partials[index] = partial
        }
    }

    /// Feed a complete (non-streamed) `message.tool_calls` array.
    mutating func ingest(complete calls: [[String: Any]]) {
        for (offset, call) in calls.enumerated() {
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            partials[partials.count + offset] = Partial(
                name: name,
                arguments: function["arguments"] as? String ?? ""
            )
        }
    }

    /// Every accumulated call rendered as fenced blocks, ready to append to
    /// the assistant message — nil when there's nothing to render. Web
    /// search isn't a real MCP server (see `WebSearchTool`), so it's
    /// checked first and rendered as its own `eaon:search` fence rather
    /// than being forced through the `eaon:mcp server=...` shape, which
    /// would also route it into the always-confirm MCP call-execution path
    /// it deliberately isn't part of. Everything else resolves through the
    /// map or the `server__tool` convention; names that resolve through
    /// neither are dropped (there is nothing valid to execute for them,
    /// and the fence would just error back).
    func fencedBlocks(nameMap: [String: (server: String, tool: String)]) -> String? {
        let ordered = partials.keys.sorted().compactMap { partials[$0] }
        let blocks = ordered.compactMap { partial -> String? in
            guard !partial.name.isEmpty else { return nil }
            let args = partial.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.name == WebSearchTool.nativeFunctionName {
                return "```eaon:search\n\(args.isEmpty ? "{}" : args)\n```"
            }
            if partial.name == ImageGenerationTool.nativeFunctionName {
                return "```eaon:image\n\(args.isEmpty ? "{}" : args)\n```"
            }
            // Desktop-control tools (`computer_<tool>`) are checked before the
            // MCP `server__tool` split — their single-underscore prefix can't
            // collide with the double-underscore convention, and they route
            // to their own `eaon:computer` fence, not the MCP path.
            if let desktopTool = DesktopControlTool.tool(forNativeName: partial.name) {
                return "```eaon:computer tool=\"\(desktopTool.rawValue)\"\n\(args.isEmpty ? "{}" : args)\n```"
            }
            guard let resolved = nameMap[partial.name] ?? Self.splitNamespaced(partial.name) else { return nil }
            return "```eaon:mcp server=\"\(resolved.server)\" tool=\"\(resolved.tool)\"\n\(args.isEmpty ? "{}" : args)\n```"
        }
        guard !blocks.isEmpty else { return nil }
        return "\n\n" + blocks.joined(separator: "\n\n")
    }

    private static func splitNamespaced(_ name: String) -> (server: String, tool: String)? {
        guard let range = name.range(of: "__"), range.lowerBound != name.startIndex else { return nil }
        let tool = String(name[range.upperBound...])
        guard !tool.isEmpty else { return nil }
        return (String(name[..<range.lowerBound]), tool)
    }
}
