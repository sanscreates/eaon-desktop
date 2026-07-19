import Foundation

/// Thread-safe holder for the `URLSession` the app's outbound provider/web
/// traffic uses. Network code runs off the main actor, so it can't read the
/// `@MainActor ProxyStore` directly — instead `ProxyStore` pushes a freshly
/// built session here whenever proxy settings change, and any context reads
/// it cheaply. Defaults to a plain session, so before `ProxyStore` is ever
/// touched (or whenever the proxy is off) this behaves exactly like the
/// `URLSession.shared` it replaced.
enum AppHTTP {
    private static let lock = NSLock()
    private static var _session = URLSession(configuration: .default)

    static var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        return _session
    }

    static func replaceSession(_ session: URLSession) {
        lock.lock(); _session = session; lock.unlock()
    }
}

/// Persists an optional HTTP/HTTPS proxy (Settings → Tools → Network) and
/// rebuilds `AppHTTP.session` to route through it — for users behind a
/// corporate or firewalled network that requires one. Off by default, in
/// which case the app's traffic goes out directly, unchanged.
///
/// Storage is UserDefaults, matching this app's deliberate choice to keep
/// secrets out of the Keychain (see `APIKeyStore` for the ad-hoc-signing
/// reason). Authenticated proxies (username/password) aren't wired yet —
/// this covers the common host:port case; the field would be a small
/// addition once there's a real authenticated proxy to verify against.
@MainActor
@Observable
final class ProxyStore {
    static let shared = ProxyStore()

    var isEnabled: Bool { didSet { persistAndRebuild() } }
    var host: String { didSet { persistAndRebuild() } }
    var port: Int { didSet { persistAndRebuild() } }

    private static let key = "http_proxy_v1"

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        isEnabled = stored["isEnabled"] as? Bool ?? false
        host = stored["host"] as? String ?? ""
        port = stored["port"] as? Int ?? 8080
        rebuildSession()
    }

    /// Whether the current settings actually describe a usable proxy — an
    /// enabled-but-blank config sends traffic directly rather than to
    /// nowhere.
    var isActive: Bool {
        isEnabled && !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }

    private func persistAndRebuild() {
        UserDefaults.standard.set([
            "isEnabled": isEnabled,
            "host": host,
            "port": port,
        ], forKey: Self.key)
        rebuildSession()
    }

    private func rebuildSession() {
        let config = URLSessionConfiguration.default
        if isActive {
            let trimmedHost = host.trimmingCharacters(in: .whitespaces)
            // Route both HTTP and HTTPS through the same host:port. The
            // provider traffic is all HTTPS, so the HTTPS keys are the ones
            // that actually matter; the HTTP keys are set too for any plain
            // HTTP endpoint (e.g. a local model server addressed by name).
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: trimmedHost,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: trimmedHost,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        AppHTTP.replaceSession(URLSession(configuration: config))
    }
}
