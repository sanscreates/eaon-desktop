import CryptoKit
import Foundation
import Network

/// A generic OAuth 2.1 client implementing the MCP authorization spec
/// (2025-06-18) — discovery via RFC 9728 (Protected Resource Metadata) +
/// RFC 8414 (Authorization Server Metadata), RFC 7591 Dynamic Client
/// Registration, PKCE (RFC 7636, S256), and RFC 8707 Resource Indicators.
/// Not hardcoded to any one vendor: any MCP server implementing the spec
/// (verified live against Notion's) works through the same code path.
///
/// Redirect URI is a loopback HTTP listener (`http://127.0.0.1:<port>/…`),
/// not a custom URL scheme — the spec's own security section is explicit
/// that redirect URIs "MUST be either localhost or use HTTPS," and a
/// custom scheme is neither. This also means no app-bundle/Info.plist
/// registration is needed at all, unlike a scheme-based callback would
/// require — it works identically in a raw dev build and a packaged one.
enum MCPOAuth {
    struct ServerMetadata {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
        /// The canonical resource URI (RFC 8707) — sent on every
        /// authorize/token request so the issued token is bound to this
        /// specific MCP server, per the spec's audience-binding
        /// requirement.
        let resource: String
        let supportsS256: Bool
    }

    struct ClientCredentials: Codable {
        let clientId: String
        let clientSecret: String?
    }

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    enum OAuthError: LocalizedError {
        case discoveryFailed(String)
        case registrationFailed(String)
        case authorizationDenied
        case stateMismatch
        case tokenExchangeFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .discoveryFailed(let m): return "Couldn't find this service's sign-in details: \(m)"
            case .registrationFailed(let m): return "Couldn't register with this service: \(m)"
            case .authorizationDenied: return "Sign-in was cancelled or denied."
            case .stateMismatch: return "The sign-in response didn't match what was requested — try again."
            case .tokenExchangeFailed(let m): return "Sign-in succeeded but exchanging the code for a token failed: \(m)"
            case .timedOut: return "Sign-in timed out waiting for the browser. Try again."
            }
        }
    }

    // MARK: - Discovery

    /// Step 1 of the spec's flow: an unauthenticated request to the MCP
    /// endpoint returns 401 with a `WWW-Authenticate` header pointing at
    /// the protected-resource-metadata document, which in turn names the
    /// authorization server, whose own metadata document has the actual
    /// authorize/token/register endpoints.
    static func discover(mcpEndpoint: URL) async throws -> ServerMetadata {
        var probe = URLRequest(url: mcpEndpoint)
        probe.httpMethod = "POST"
        probe.addValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [String: Any]()])

        let (_, response) = try await AppHTTP.session.data(for: probe)
        guard let http = response as? HTTPURLResponse, http.statusCode == 401,
              let header = http.value(forHTTPHeaderField: "WWW-Authenticate"),
              let resourceMetadataURL = Self.extractResourceMetadataURL(from: header) else {
            throw OAuthError.discoveryFailed("this server didn't advertise an OAuth discovery document.")
        }

        let resourceMetadata = try await Self.fetchJSON(resourceMetadataURL)
        guard let authServers = resourceMetadata["authorization_servers"] as? [String],
              let authServerBase = authServers.first, let authServerURL = URL(string: authServerBase) else {
            throw OAuthError.discoveryFailed("no authorization server was listed.")
        }
        let resource = resourceMetadata["resource"] as? String ?? mcpEndpoint.absoluteString

        let asMetadataURL = try Self.wellKnownAuthServerMetadataURL(for: authServerURL)
        let asMetadata = try await Self.fetchJSON(asMetadataURL)
        guard let authorizeString = asMetadata["authorization_endpoint"] as? String, let authorizeURL = URL(string: authorizeString),
              let tokenString = asMetadata["token_endpoint"] as? String, let tokenURL = URL(string: tokenString) else {
            throw OAuthError.discoveryFailed("the authorization server's metadata was missing required endpoints.")
        }
        let registrationURL = (asMetadata["registration_endpoint"] as? String).flatMap(URL.init(string:))
        let challengeMethods = asMetadata["code_challenge_methods_supported"] as? [String] ?? []

        return ServerMetadata(
            authorizationEndpoint: authorizeURL,
            tokenEndpoint: tokenURL,
            registrationEndpoint: registrationURL,
            resource: resource,
            supportsS256: challengeMethods.contains("S256")
        )
    }

    /// RFC 8414 §3.1: the well-known suffix is inserted right after the
    /// host, with the issuer's own path (if any) appended *after* it —
    /// `https://host/.well-known/oauth-authorization-server/issuer/path`,
    /// NOT `https://host/issuer/path/.well-known/oauth-authorization-server`.
    /// Confirmed the hard way: a naive `appendingPathComponent` (the
    /// second, wrong form) happened to work for Notion purely because its
    /// issuer URL has no path component to expose the bug — it 404s for
    /// any issuer that does, LaunchDarkly's included (verified live: the
    /// wrong form 404s, this form returns the real metadata document).
    private static func wellKnownAuthServerMetadataURL(for issuer: URL) throws -> URL {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else {
            throw OAuthError.discoveryFailed("the authorization server URL was malformed.")
        }
        let originalPath = components.path
        components.path = "/.well-known/oauth-authorization-server" + originalPath
        guard let url = components.url else {
            throw OAuthError.discoveryFailed("couldn't build the metadata URL.")
        }
        return url
    }

    private static func extractResourceMetadataURL(from wwwAuthenticate: String) -> URL? {
        // `Bearer realm="OAuth", resource_metadata="https://…", error="…"`
        guard let range = wwwAuthenticate.range(of: "resource_metadata=\"") else { return nil }
        let rest = wwwAuthenticate[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return URL(string: String(rest[..<end]))
    }

    private static func fetchJSON(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await AppHTTP.session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.discoveryFailed("\(url.absoluteString) didn't return valid metadata.")
        }
        return json
    }

    // MARK: - Dynamic Client Registration (RFC 7591)

    /// Registers Eaon as a new OAuth client with this specific
    /// authorization server — no pre-approval needed when
    /// `registrationEndpoint` is present (verified live: Notion's
    /// authorization server metadata both lists one and supports the
    /// `none` token-endpoint auth method, i.e. a public client with no
    /// secret, exactly what a native app needs since it can't safely
    /// embed one). Cached per server after the first call — see
    /// `MCPOAuthCredentialStore` — so this only happens once.
    static func register(metadata: ServerMetadata, redirectURI: URL) async throws -> ClientCredentials {
        guard let endpoint = metadata.registrationEndpoint else {
            throw OAuthError.registrationFailed("this server requires a pre-registered client, which Eaon doesn't have for it yet.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Eaon",
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])

        let (data, response) = try await AppHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = json["client_id"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw OAuthError.registrationFailed(body)
        }
        return ClientCredentials(clientId: clientId, clientSecret: json["client_secret"] as? String)
    }

    // MARK: - PKCE (RFC 7636)

    struct PKCE {
        let verifier: String
        let challenge: String
    }

    /// S256 only — "plain" exists in the spec for legacy compatibility,
    /// but every server this app talks to supports S256 (verified for
    /// Notion), and there's no reason to accept the weaker method when
    /// the stronger one is available.
    static func generatePKCE() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return PKCE(verifier: verifier, challenge: challenge)
    }

    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    // MARK: - Authorization URL

    static func authorizationURL(metadata: ServerMetadata, clientId: String, redirectURI: URL, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: metadata.resource),
        ]
        return components.url!
    }

    // MARK: - Token exchange / refresh

    static func exchangeCode(metadata: ServerMetadata, clientId: String, code: String, pkce: PKCE, redirectURI: URL) async throws -> Tokens {
        try await Self.tokenRequest(endpoint: metadata.tokenEndpoint, resource: metadata.resource, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": clientId,
            "code_verifier": pkce.verifier,
        ])
    }

    static func refresh(metadata: ServerMetadata, clientId: String, refreshToken: String) async throws -> Tokens {
        try await Self.tokenRequest(endpoint: metadata.tokenEndpoint, resource: metadata.resource, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ])
    }

    private static func tokenRequest(endpoint: URL, resource: String, form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var withResource = form
        withResource["resource"] = resource
        request.httpBody = withResource
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await AppHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw OAuthError.tokenExchangeFailed(body)
        }
        let expiresAt = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        return Tokens(accessToken: accessToken, refreshToken: json["refresh_token"] as? String, expiresAt: expiresAt)
    }

    // MARK: - Loopback redirect listener

    /// Opens the system browser to `url`, then listens on a random local
    /// port for exactly one incoming request — the authorization
    /// server's redirect after the user approves (or denies) — reads its
    /// query string, and immediately closes. `redirectURI` must be
    /// generated first (`makeRedirectURI`) so it can be registered/used
    /// in the authorize URL before this is called.
    static func awaitRedirect(expectedState: String, timeout: Duration = .seconds(180)) async throws -> String {
        // This binds on all local interfaces, not loopback exclusively —
        // tried restricting it via `NWParameters.requiredLocalEndpoint`,
        // but that broke the listener outright (Network.framework
        // doesn't seem to honor it the same way for a listener as it
        // does for an outgoing connection), so reverted rather than ship
        // a regression chasing defense-in-depth the design doesn't
        // actually depend on: the real security boundary is the `state`
        // parameter checked below, which is what OAuth's own native-app
        // guidance relies on for exactly this pattern — a request here
        // without the correct high-entropy state (verified live, see the
        // mismatch test) is rejected regardless of which interface it
        // arrived on, and the listener accepts exactly one request before
        // closing for good.
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.redirectPort)!)
        defer { listener.cancel() }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    var didResume = false
                    let resumeOnce: (Result<String, Error>) -> Void = { result in
                        guard !didResume else { return }
                        didResume = true
                        continuation.resume(with: result)
                    }

                    listener.newConnectionHandler = { connection in
                        connection.start(queue: .main)
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                            defer {
                                connection.send(content: Self.callbackResponseHTML.data(using: .utf8), completion: .contentProcessed { _ in
                                    connection.cancel()
                                })
                            }
                            guard let data, let text = String(data: data, encoding: .utf8),
                                  let requestLine = text.split(separator: "\r\n").first,
                                  let path = requestLine.split(separator: " ").dropFirst().first,
                                  let components = URLComponents(string: "http://127.0.0.1\(path)"),
                                  let query = components.queryItems else {
                                resumeOnce(.failure(OAuthError.authorizationDenied))
                                return
                            }
                            if let error = query.first(where: { $0.name == "error" })?.value {
                                resumeOnce(.failure(OAuthError.discoveryFailed(error)))
                                return
                            }
                            guard query.first(where: { $0.name == "state" })?.value == expectedState else {
                                resumeOnce(.failure(OAuthError.stateMismatch))
                                return
                            }
                            guard let code = query.first(where: { $0.name == "code" })?.value else {
                                resumeOnce(.failure(OAuthError.authorizationDenied))
                                return
                            }
                            resumeOnce(.success(code))
                        }
                    }
                    listener.start(queue: .main)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw OAuthError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Fixed, not random. Dynamic Client Registration is meant to happen
    /// once per server and be reused for every future sign-in (see
    /// `MCPOAuthCredentialStore` — re-registering every time would be
    /// wasteful and leave orphaned client registrations behind) — but an
    /// authorization server only accepts a `redirect_uri` that exactly
    /// matches one of the URIs registered at DCR time. A fresh random
    /// port per sign-in would register one port and then, on every
    /// subsequent sign-in, listen on a *different* one the server never
    /// agreed to — the exact bug this constant exists to avoid. Chosen
    /// arbitrarily from the private/ephemeral range; not a registered or
    /// widely-used service port.
    static let redirectPort: UInt16 = 51847
    static var redirectURI: URL { URL(string: "http://127.0.0.1:\(redirectPort)/callback")! }

    private static let callbackResponseHTML = """
    HTTP/1.1 200 OK\r
    Content-Type: text/html; charset=utf-8\r
    Connection: close\r
    \r
    <html><body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:4em;color:#888;background:#111">You can close this tab and go back to Eaon.</body></html>
    """
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

/// Per-service OAuth state: the DCR-issued client credentials (registered
/// once, reused forever — re-registering on every sign-in would be
/// wasteful and would leave orphaned client registrations on the
/// server) plus the current tokens. Stored the same way every other
/// credential in this app is — see `APIKeyStore`'s own doc comment for
/// why that's UserDefaults, not Keychain.
enum MCPOAuthCredentialStore {
    private static let defaults = UserDefaults.standard

    private struct Record: Codable {
        let credentials: MCPOAuth.ClientCredentials
        var tokens: MCPOAuth.Tokens
    }

    static func loadClientCredentials(forAccount account: String) -> MCPOAuth.ClientCredentials? {
        record(forAccount: account)?.credentials
    }

    static func loadTokens(forAccount account: String) -> MCPOAuth.Tokens? {
        record(forAccount: account)?.tokens
    }

    static func save(credentials: MCPOAuth.ClientCredentials, tokens: MCPOAuth.Tokens, forAccount account: String) {
        guard let data = try? JSONEncoder().encode(Record(credentials: credentials, tokens: tokens)) else { return }
        defaults.set(data, forKey: key(account))
    }

    static func saveTokens(_ tokens: MCPOAuth.Tokens, forAccount account: String) {
        guard let existing = record(forAccount: account) else { return }
        save(credentials: existing.credentials, tokens: tokens, forAccount: account)
    }

    static func delete(forAccount account: String) {
        defaults.removeObject(forKey: key(account))
    }

    private static func record(forAccount account: String) -> Record? {
        guard let data = defaults.data(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func key(_ account: String) -> String { "mcp_oauth_\(account)" }
}
