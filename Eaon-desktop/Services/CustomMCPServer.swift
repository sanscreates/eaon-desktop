import Foundation

/// A user-added MCP server reached by URL — the arbitrary-endpoint escape
/// hatch `MCPCatalog`'s fixed, individually-verified catalog deliberately
/// doesn't offer. `MCPClient` already speaks the generic Streamable-HTTP
/// JSON-RPC protocol (built vendor-agnostic from day one) and `MCPConnectionStore`
/// already operates on any `MCPServerDefinition` value, not just catalog
/// members — so this is purely a storage model plus a converter into that
/// existing, unmodified machinery, mirroring `CustomProviderConfig`'s exact
/// role for models.
///
/// Scoped to pasted-token auth only (not OAuth) — a real OAuth flow assumes
/// RFC 9728/8414/7591 discovery support, which is reasonable to assume for
/// major vendors already individually verified in `MCPCatalog` but not for
/// an arbitrary server a user pastes a URL for.
struct CustomMCPServer: Identifiable, Codable, Equatable {
    var id = UUID()
    var displayName: String
    /// Raw string as entered — validated into a real `URL` only at the
    /// point of use (`definition`), so a momentarily-invalid in-progress
    /// edit in the add form never crashes anything.
    var endpoint: String
    /// The `Authorization` header's scheme word. Defaults to "Bearer" (what
    /// the overwhelming majority of real MCP servers use — see
    /// `MCPServerDefinition.authScheme`'s own doc for why this varies at
    /// all), editable for the rare server that needs something else.
    var authScheme: String = "Bearer"
    var createdAt: Date = Date()
}

/// Owns every custom MCP server the user has added — storage plus the
/// conversion into a real `MCPServerDefinition`, so `MCPConnectionStore`,
/// `MCPClient`, and the Plugins page all work with custom servers through
/// the exact same code path as the built-in catalog, unmodified.
@MainActor
@Observable
final class CustomMCPServerStore {
    static let shared = CustomMCPServerStore()

    private let storageKey = "eaon_custom_mcp_servers"
    private(set) var servers: [CustomMCPServer] = []

    private init() {
        load()
    }

    var sortedServers: [CustomMCPServer] {
        servers.sorted { $0.createdAt < $1.createdAt }
    }

    /// Every stored custom server as a real `MCPServerDefinition` — merged
    /// into `MCPCatalog.available`, so every existing consumer (the Plugins
    /// page, tool dispatch, the reconnect-at-launch loop) picks these up
    /// automatically. Silently drops an entry whose `endpoint` isn't a
    /// valid URL right now rather than crashing the whole list over one bad
    /// in-progress edit.
    var definitions: [MCPServerDefinition] {
        sortedServers.compactMap { server in
            guard let url = URL(string: server.endpoint) else { return nil }
            return MCPServerDefinition(
                id: Self.definitionId(for: server.id),
                displayName: server.displayName,
                summary: server.endpoint,
                endpoint: url,
                authMode: .pastedToken,
                authScheme: server.authScheme,
                extraHeaders: [:],
                tokenCreationURL: nil,
                tokenCreationURLIsPrefilled: false,
                tokenFieldPlaceholder: "Paste an API token for this server",
                tokenHint: nil,
                manualClientIdSetupURL: nil,
                manualClientIdHint: nil,
                tokenAccount: Self.tokenAccount(for: server.id),
                logoAssetName: "custom-mcp-server" // no matching asset — PluginRow's badge already falls back to a generic icon when BrandLogoLoader finds nothing.
            )
        }
    }

    static func tokenAccount(for id: UUID) -> String {
        "custom-mcp-\(id.uuidString)"
    }

    private static func definitionId(for id: UUID) -> String {
        "custom-\(id.uuidString)"
    }

    /// Adds a new server (or updates one being edited, if `server.id`
    /// already exists) and, when a non-empty token is given, saves it —
    /// mirroring `MCPConnectionStore.connect`'s own rule of never
    /// persisting a token until it's actually been provided.
    func save(_ server: CustomMCPServer, token: String) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            try? APIKeyStore.saveAPIKey(trimmedToken, forAccount: Self.tokenAccount(for: server.id))
        }
        persist()
    }

    /// Disconnects it first (so `MCPConnectionStore` doesn't keep a live
    /// client around for a server that no longer exists) and forgets its
    /// token, then removes the entry entirely.
    func remove(_ id: UUID) {
        if let server = servers.first(where: { $0.id == id }),
           let url = URL(string: server.endpoint) {
            let definition = MCPServerDefinition(
                id: Self.definitionId(for: id), displayName: server.displayName, summary: "",
                endpoint: url, authMode: .pastedToken, authScheme: server.authScheme, extraHeaders: [:],
                tokenCreationURL: nil, tokenCreationURLIsPrefilled: false, tokenFieldPlaceholder: "",
                tokenHint: nil, manualClientIdSetupURL: nil, manualClientIdHint: nil,
                tokenAccount: Self.tokenAccount(for: id), logoAssetName: "custom-mcp-server"
            )
            MCPConnectionStore.shared.disconnect(definition)
        }
        servers.removeAll { $0.id == id }
        APIKeyStore.deleteAPIKey(forAccount: Self.tokenAccount(for: id))
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CustomMCPServer].self, from: data) else { return }
        servers = decoded
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
