import AppKit
import Foundation
import SwiftUI

// MARK: - Keep-alive

/// How long an idle Ollama model stays loaded before Ollama frees its RAM.
/// Maps directly to Ollama's own `keep_alive` duration string format.
enum OllamaKeepAliveDuration: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case untilRestart = "-1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveMinutes: return "5 minutes (Ollama's default)"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .untilRestart: return "Until Ollama restarts"
        }
    }
}

// MARK: - Backends

/// The three local-inference engines the app can drive. All of them expose
/// an OpenAI-compatible HTTP endpoint on localhost, so chat streaming reuses
/// the exact same wire code as remote providers — the only genuinely new
/// machinery is discovery and process management.
enum LocalBackend: String, Codable, CaseIterable, Identifiable {
    case ollama
    case llamaCpp
    case mlx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .llamaCpp: return "Llama.cpp"
        case .mlx: return "MLX"
        }
    }

    var blurb: String {
        switch self {
        case .ollama: return "Run models you've pulled with Ollama — private, on this Mac."
        case .llamaCpp: return "Run GGUF models from Hugging Face or files on disk, via llama.cpp."
        case .mlx: return "Run MLX models from Hugging Face on Apple silicon."
        }
    }

    var systemIcon: String {
        switch self {
        case .ollama: return "shippingbox.fill"
        case .llamaCpp: return "cpu.fill"
        case .mlx: return "memorychip.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ollama: return Color(hex: "#9CA3AF")
        case .llamaCpp: return Color(hex: "#F59E0B")
        case .mlx: return Color(hex: "#64D2FF")
        }
    }

    /// Localhost port the backend serves on. Ollama's is its own fixed
    /// default; the spawned servers use uncommon ports to avoid clashes.
    var port: Int {
        switch self {
        case .ollama: return 11434
        case .llamaCpp: return 8586
        case .mlx: return 8587
        }
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    var installCommand: String {
        switch self {
        case .ollama: return "brew install ollama"
        case .llamaCpp: return "brew install llama.cpp"
        case .mlx: return "pip3 install mlx-lm"
        }
    }

    var installNote: String {
        switch self {
        case .ollama:
            return "Ollama isn't on this Mac yet. Install it with Homebrew (or download the app from ollama.com), then come back here."
        case .llamaCpp:
            return "llama.cpp isn't on this Mac yet. Install it with Homebrew, then come back here."
        case .mlx:
            return "The MLX language-model server isn't on this Mac yet. Install it with pip, then come back here."
        }
    }

    /// The executable that proves the backend is installed.
    var binaryName: String {
        switch self {
        case .ollama: return "ollama"
        case .llamaCpp: return "llama-server"
        case .mlx: return "mlx_lm.server"
        }
    }
}

// MARK: - Model record

/// One locally-runnable model. `id` is namespaced ("ollama:llama3.2:latest")
/// so a local model can never collide with an Aqua or BYOK model id — Aqua
/// really does serve ids like "deepseek-v4-pro" that also exist as Ollama
/// tags on this machine.
struct LocalModelRecord: Identifiable, Codable, Equatable {
    var id: String
    /// What actually goes in the request's "model" field.
    var requestModelId: String
    var backend: LocalBackend
    var displayName: String
    var detail: String
    /// llama.cpp/MLX: the Hugging Face repo or GGUF file path to launch with.
    /// Optional (not `= ""`) because every Ollama-sourced record is built
    /// without passing this at all — real evidence this field was added
    /// after Ollama-only records already existed and got persisted, so a
    /// non-optional default here would silently wipe the user's whole
    /// added-local-model list on decode (same class of bug as
    /// `ChatMessage.wasColdLoad` — see its doc comment).
    var source: String?
    var isFile: Bool?
    var addedAt: Date?
}

// MARK: - Curated catalog (data-driven)

/// Loads and validates `CuratedOllamaModels.json` — the bundled, data-driven
/// source for the Models page's "Popular"/family/use-case sections. This is
/// deliberately the one part of the model catalog kept as data rather than
/// Swift: it changes weekly as new models ship, unlike `ProviderBrand`
/// (still a Swift enum on purpose — a new *company* is rare, and the
/// compiler's exhaustive-switch checking on brand identity is worth more
/// than it costs).
enum CuratedOllamaCatalog {
    private struct File: Decodable {
        struct Entry: Decodable {
            let name: String
            let blurb: String
            let approxSize: String
            let sizeBytes: Int64
            /// The raw `ProviderBrand` case name (e.g. `"meta"`), or absent
            /// entirely for an entry with no single company to credit — see
            /// `LocalAIManager.CuratedOllamaModel.brand`'s own doc comment.
            let brand: String?
            let category: String
        }
        let categoryOrder: [String]
        let models: [Entry]
    }

    private static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Eaon-desktop_Eaon-desktop", withExtension: "bundle"),
           let resourceBundle = Bundle(url: url) {
            return resourceBundle
        }
        return Bundle.module
    }()

    /// Loads, decodes, and validates the bundled JSON. Every failure mode —
    /// missing file, malformed JSON, or a `brand` string that doesn't match
    /// any real `ProviderBrand` case — crashes immediately and says exactly
    /// what's wrong, rather than silently dropping an entry or falling back
    /// to something that quietly ships broken. A typo here should be
    /// impossible to miss during any normal test pass, not a subtle bug a
    /// user discovers later.
    static func loadOrFail() -> (categoryOrder: [String], models: [LocalAIManager.CuratedOllamaModel]) {
        guard let url = bundle.url(forResource: "CuratedOllamaModels", withExtension: "json") else {
            fatalError("CuratedOllamaModels.json is missing from the app bundle — the curated Ollama model list can't load.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fatalError("Could not read CuratedOllamaModels.json: \(error)")
        }

        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            fatalError("CuratedOllamaModels.json failed to decode — check its structure against CuratedOllamaCatalog.File: \(error)")
        }

        let models = file.models.map { entry -> LocalAIManager.CuratedOllamaModel in
            let brand: ProviderBrand?
            if let brandString = entry.brand {
                guard let resolved = ProviderBrand(rawValue: brandString) else {
                    fatalError("""
                        CuratedOllamaModels.json: "\(entry.name)" references brand \"\(brandString)\", \
                        which isn't a real ProviderBrand case. Fix the JSON entry, or add \
                        `case \(brandString)` to ProviderBrand in ModelCatalog.swift if it's a real new company.
                        """)
                }
                brand = resolved
            } else {
                brand = nil
            }
            return LocalAIManager.CuratedOllamaModel(
                name: entry.name,
                blurb: entry.blurb,
                approxSize: entry.approxSize,
                sizeBytes: entry.sizeBytes,
                brand: brand,
                category: entry.category
            )
        }

        return (file.categoryOrder, models)
    }
}

// MARK: - Manager

/// Owns local-backend detection, Ollama's live model list, the user's added
/// llama.cpp/MLX models, and the lifecycle of spawned inference servers.
@MainActor
@Observable
final class LocalAIManager {
    static let shared = LocalAIManager()

    private(set) var installed: Set<LocalBackend> = []
    private(set) var ollamaReachable = false
    private(set) var ollamaModels: [LocalModelRecord] = []
    /// Persisted llama.cpp/MLX models the user added by repo or file.
    private(set) var userModels: [LocalModelRecord] = []
    /// Tail of each backend's server output — shown in its settings page.
    private(set) var serverLogs: [LocalBackend: String] = [:]
    /// The spawned inference server currently running (one at a time — these
    /// models eat RAM; running several at once would drown the machine).
    private(set) var activeSpawned: (backend: LocalBackend, modelId: String)?
    private(set) var isStartingServer = false
    private(set) var startupStatus: String?
    private(set) var isPulling = false
    private(set) var pullStatus: String?
    /// How long an idle Ollama model stays resident before Ollama frees its
    /// RAM — user-configurable because the right tradeoff depends on the
    /// machine (a Studio with 128GB might want models to just stay loaded;
    /// a 16GB laptop wants them gone fast). Only takes effect via
    /// `primeOllamaModel` — see its doc comment for why.
    var ollamaKeepAliveDuration: OllamaKeepAliveDuration {
        didSet { UserDefaults.standard.set(ollamaKeepAliveDuration.rawValue, forKey: Self.keepAliveDurationKey) }
    }

    private var spawnedProcess: Process?
    private var managedOllama: Process?
    private static let userModelsKey = "aqua_local_models"
    private static let keepAliveDurationKey = "ollama_keep_alive_duration"

    private init() {
        ollamaKeepAliveDuration = OllamaKeepAliveDuration(
            rawValue: UserDefaults.standard.string(forKey: Self.keepAliveDurationKey) ?? ""
        ) ?? .fiveMinutes
        loadUserModels()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAllServers() }
        }
        Task { await bootstrap() }
    }

    func bootstrap() async {
        detectInstalledBackends()
        await refreshOllamaModels()
    }

    // MARK: Detection

    func detectInstalledBackends() {
        var found: Set<LocalBackend> = []
        for backend in LocalBackend.allCases {
            if resolveBinary(backend.binaryName) != nil {
                found.insert(backend)
            }
        }
        installed = found
    }

    /// Finds an executable the way a login shell would, plus the usual
    /// Homebrew/pip locations a GUI app's bare PATH misses.
    private func resolveBinary(_ name: String) -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            NSHomeDirectory() + "/.local/bin",
        ]
        // pip --user installs console scripts under ~/Library/Python/<ver>/bin
        let pythonRoot = NSHomeDirectory() + "/Library/Python"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: pythonRoot) {
            directories += versions.map { pythonRoot + "/" + $0 + "/bin" }
        }

        for directory in directories {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: Ollama models

    struct OllamaTagsResponse: Codable {
        struct Model: Codable {
            let name: String
            let size: Int64?
            let remote_host: String?
        }
        let models: [Model]
    }

    /// Refreshes the live list of Ollama models. Cloud-proxied entries
    /// (remote_host set) are excluded — they run on ollama.com, not this Mac
    /// — and embedding models are excluded because they can't chat.
    func refreshOllamaModels(startServerIfNeeded: Bool = false) async {
        guard installed.contains(.ollama) else {
            ollamaModels = []
            ollamaReachable = false
            return
        }

        if let tags = await fetchOllamaTags() {
            applyOllamaTags(tags)
            return
        }

        if startServerIfNeeded, startManagedOllamaServe() {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if let tags = await fetchOllamaTags() {
                    applyOllamaTags(tags)
                    return
                }
            }
        }

        ollamaReachable = false
        ollamaModels = []
    }

    private func applyOllamaTags(_ tags: OllamaTagsResponse) {
        ollamaReachable = true
        ollamaModels = tags.models
            .filter { $0.remote_host == nil && !$0.name.localizedCaseInsensitiveContains("embed") }
            .map { model in
                LocalModelRecord(
                    id: "ollama:\(model.name)",
                    requestModelId: model.name,
                    backend: .ollama,
                    displayName: model.name,
                    detail: Self.formatBytes(model.size)
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func fetchOllamaTags() async -> OllamaTagsResponse? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(OllamaTagsResponse.self, from: data)
    }

    /// A model only actually loads into memory on its first real request —
    /// Ollama itself stays running independent of this app, so "the server
    /// is up" says nothing about whether *this specific* model still needs
    /// a cold load. `/api/ps` lists everything currently resident, with its
    /// real memory footprint — verified live against this Mac's own Ollama
    /// (confirmed: `models[].name` matches the request model id exactly,
    /// `size_vram` is the real resident byte count).
    struct OllamaModelStatus {
        let sizeVRAMBytes: Int64
        let contextLength: Int?
    }

    func ollamaModelStatus(_ modelId: String) async -> OllamaModelStatus? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/ps")!)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]],
              let match = models.first(where: { ($0["name"] as? String) == modelId }),
              let sizeVRAM = match["size_vram"] as? NSNumber else { return nil }
        let contextLength = (match["context_length"] as? NSNumber)?.intValue
        return OllamaModelStatus(sizeVRAMBytes: sizeVRAM.int64Value, contextLength: contextLength)
    }

    private static func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "On this Mac" }
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 { return String(format: "%.1f GB on this Mac", gigabytes) }
        return String(format: "%.0f MB on this Mac", gigabytes * 1000)
    }

    /// Loads a model into memory (if not already) and/or (re)sets how long
    /// it stays resident, via a native `/api/generate` ping with no
    /// `prompt` field — verified empirically to load-without-generating
    /// (Ollama returns `done_reason: "load"`, zero tokens) and to honor
    /// `keep_alive` exactly. This has to be a separate native call: actual
    /// chat completions stream through the OpenAI-compatible endpoint
    /// (`CustomProviderAPIService`), and that endpoint silently ignores a
    /// `keep_alive` field in the body — verified live, it just falls back
    /// to Ollama's hardcoded 5-minute default regardless of what's sent.
    /// Fire-and-forget: any failure here just means that 5-minute default
    /// applies instead, never worse than before this existed.
    @discardableResult
    func primeOllamaModel(_ modelId: String, keepAlive: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": modelId,
            "keep_alive": keepAlive,
        ])
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Pull (Ollama)

    /// Streams `ollama pull` progress via the NDJSON /api/pull endpoint.
    func pullOllamaModel(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPulling else { return }
        isPulling = true
        pullingModelName = trimmed
        pullStatus = "Starting download of \(trimmed)…"
        defer {
            isPulling = false
            pullingModelName = nil
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/pull")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": trimmed, "stream": true])

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                pullStatus = "Could not start the download — is the model name right?"
                return
            }
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let error = json["error"] as? String {
                    pullStatus = "Error: \(error)"
                    return
                }
                let status = json["status"] as? String ?? ""
                if let completed = json["completed"] as? Double, let total = json["total"] as? Double, total > 0 {
                    pullStatus = "\(status) — \(Int(completed / total * 100))%"
                } else if !status.isEmpty {
                    pullStatus = status
                }
            }
            pullStatus = "Done — \(trimmed) is ready."
            await refreshOllamaModels()
        } catch {
            pullStatus = "Download failed: \(error.localizedDescription)"
        }
    }

    /// Looks up a model's real download size from Ollama's own public
    /// registry — used to show a fit estimate for a name the user typed in
    /// that isn't part of the curated list, before they actually pull it.
    /// Returns nil for a name that doesn't exist (the pull itself will
    /// surface that error) or on any network failure.
    func fetchOllamaRegistrySize(name: String) async -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        let repo = String(parts[0])
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        guard let url = URL(string: "https://registry.ollama.ai/v2/library/\(repo)/manifests/\(tag)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.addValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // JSONSerialization hands back numbers as NSNumber, not directly as
        // Int64 — going through .int64Value is the safe unwrap.
        let configSize = ((json["config"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? 0
        let layers = json["layers"] as? [[String: Any]] ?? []
        let layersSize = layers.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) }
        let total = configSize + layersSize
        return total > 0 ? total : nil
    }

    // MARK: Ollama delete

    /// Removes a model from Ollama's local store (DELETE /api/delete).
    func deleteOllamaModel(_ name: String) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/delete")!)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name])
        _ = try? await URLSession.shared.data(for: request)
        await refreshOllamaModels()
    }

    /// The single, backend-aware place to delete any local model — Ollama's
    /// own store for Ollama models, the app's own record (and file, if it's
    /// one the app downloaded) for llama.cpp/MLX ones. Every delete button
    /// in the app should route through this rather than picking a backend's
    /// method itself: `removeUserModel` only touches the llama.cpp/MLX list,
    /// so calling it directly for an Ollama model silently does nothing.
    func deleteModel(_ record: LocalModelRecord) async {
        switch record.backend {
        case .ollama:
            await deleteOllamaModel(record.requestModelId)
        case .llamaCpp, .mlx:
            removeUserModel(id: record.id)
        }
    }

    // MARK: Hugging Face discovery + downloads

    struct HFSearchResult: Identifiable, Equatable {
        let id: String
        let downloads: Int
        let likes: Int
    }

    struct ModelDownloadState: Equatable {
        var status: String
        /// 0...1 when the total size is known, nil while indeterminate.
        var fraction: Double?
        var failed = false
        var finished = false
    }

    /// Active/finished Hugging Face downloads, keyed by repo id.
    private(set) var hfDownloads: [String: ModelDownloadState] = [:]
    private var hfDownloadTasks: [String: Task<Void, Never>] = [:]

    /// Live search of Hugging Face's public model API, restricted to GGUF
    /// text-generation repos (what llama.cpp can actually run).
    /// An empty query returns the current most-downloaded GGUF models across
    /// all of Hugging Face instead of matching nothing — used to show a live
    /// "Trending" list by default, so the tab never opens to a blank "type
    /// something" prompt (verified: an empty `search=` param behaves
    /// identically to omitting it, so this is the same call either way).
    func searchHuggingFaceGGUF(_ query: String, limit: Int = 25) async -> [HFSearchResult] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        var items = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "pipeline_tag", value: "text-generation"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if !query.isEmpty {
            items.append(URLQueryItem(name: "search", value: query))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        struct APIEntry: Codable {
            let id: String
            let downloads: Int?
            let likes: Int?
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([APIEntry].self, from: data) else { return [] }
        return entries.map { HFSearchResult(id: $0.id, downloads: $0.downloads ?? 0, likes: $0.likes ?? 0) }
    }

    /// Where in-app Hugging Face downloads live — files here are ours to
    /// delete when their model is removed (never user-picked files).
    static var managedModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AquaChat/Models", isDirectory: true)
    }

    /// True once a repo's file has been downloaded and registered.
    func isHFRepoDownloaded(_ repo: String) -> Bool {
        userModels.contains { $0.detail.contains(repo) }
    }

    func downloadedModelId(forRepo repo: String) -> String? {
        userModels.first { $0.detail.contains(repo) }?.id
    }

    /// `file` lets the user override the auto-picked quantization (from
    /// `listGGUFFiles`) — nil keeps the one-click default behavior.
    /// `onComplete` fires exactly once, with the newly-downloaded model's
    /// id (nil on failure/cancel) — the one-click "download it and take me
    /// to chat with it" flow hangs off this rather than the caller having
    /// to poll or diff `hfDownloads` itself.
    func startHFDownload(repo: String, file: GGUFFile? = nil, onComplete: @escaping (String?) -> Void = { _ in }) {
        guard hfDownloadTasks[repo] == nil else { return }
        hfDownloads[repo] = ModelDownloadState(status: file == nil ? "Finding the best file…" : "Starting download…", fraction: nil)
        hfDownloadTasks[repo] = Task { [weak self] in
            let resultId = await self?.runHFDownload(repo: repo, file: file)
            self?.hfDownloadTasks[repo] = nil
            onComplete(resultId)
        }
    }

    func cancelHFDownload(repo: String) {
        hfDownloadTasks[repo]?.cancel()
    }

    /// Returns the resulting `LocalModelRecord.id` on success, nil on
    /// failure/cancellation.
    @discardableResult
    private func runHFDownload(repo: String, file explicitFile: GGUFFile? = nil) async -> String? {
        do {
            let file: (path: String, size: Int64)
            if let explicitFile {
                file = (explicitFile.path, explicitFile.size)
            } else {
                file = try await resolveGGUFFile(repo: repo)
            }
            let sizeText = Self.formatBytes(file.size).replacingOccurrences(of: " on this Mac", with: "")

            let directory = Self.managedModelsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = repo.replacingOccurrences(of: "/", with: "_") + "__" + (file.path as NSString).lastPathComponent
            let destination = directory.appendingPathComponent(fileName)

            if !FileManager.default.fileExists(atPath: destination.path) {
                hfDownloads[repo] = ModelDownloadState(status: "Downloading \(sizeText)…", fraction: file.size > 0 ? 0 : nil)
                guard let sourceURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.path)") else {
                    throw URLError(.badURL)
                }
                try await Self.downloadFile(from: sourceURL, to: destination, expectedSize: file.size) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, var state = self.hfDownloads[repo], !state.finished else { return }
                        state.fraction = fraction
                        state.status = "Downloading \(sizeText) — \(Int(fraction * 100))%"
                        self.hfDownloads[repo] = state
                    }
                }
            }

            let quant = Self.quantLabel(from: file.path)
            let record = LocalModelRecord(
                id: "llamacpp:\(destination.path)",
                requestModelId: (repo as NSString).lastPathComponent,
                backend: .llamaCpp,
                displayName: (repo as NSString).lastPathComponent + (quant.isEmpty ? "" : " · \(quant)"),
                detail: "\(sizeText) · from \(repo)",
                source: destination.path,
                isFile: true
            )
            if !userModels.contains(where: { $0.id == record.id }) {
                userModels.append(record)
                persistUserModels()
            }
            hfDownloads[repo] = ModelDownloadState(status: "Ready — it's under \"On this Mac\"", fraction: 1, finished: true)
            return record.id
        } catch is CancellationError {
            hfDownloads[repo] = nil
            return nil
        } catch let error as URLError where error.code == .cancelled {
            hfDownloads[repo] = nil
            return nil
        } catch {
            hfDownloads[repo] = ModelDownloadState(status: "Failed: \(error.localizedDescription)", fraction: nil, failed: true)
            return nil
        }
    }

    func clearHFDownloadState(repo: String) {
        hfDownloads[repo] = nil
    }

    struct GGUFFile: Identifiable, Equatable {
        let path: String
        let size: Int64
        var id: String { path }
        var quantLabel: String { LocalAIManager.quantLabel(from: path) }
    }

    /// Every single-file GGUF candidate in a repo (skipping multi-part
    /// splits and vision projector files) — the raw list behind both
    /// `resolveGGUFFile`'s auto-pick and the quantization picker in the UI.
    private func fetchGGUFCandidates(repo: String) async throws -> [GGUFFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        struct TreeEntry: Codable {
            let path: String
            let size: Int64?
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([TreeEntry].self, from: data) else {
            throw LocalAIError.startFailed(.llamaCpp, "couldn't read that Hugging Face repo — check the name")
        }

        let candidates = entries.filter { entry in
            let lower = entry.path.lowercased()
            return lower.hasSuffix(".gguf") && !lower.contains("-of-") && !lower.contains("mmproj")
        }
        guard !candidates.isEmpty else {
            throw LocalAIError.startFailed(.llamaCpp, "that repo has no single-file GGUF models")
        }
        return candidates.map { GGUFFile(path: $0.path, size: $0.size ?? 0) }
    }

    /// Every downloadable quantization for a repo, smallest-to-largest —
    /// backs the quantization picker so a user can trade quality for size
    /// instead of always getting the one auto-picked default.
    func listGGUFFiles(repo: String) async throws -> [GGUFFile] {
        try await fetchGGUFCandidates(repo: repo).sorted { $0.size < $1.size }
    }

    /// Picks the single-file GGUF to download from a repo — Q4_K_M when
    /// available (the standard quality/size sweet spot), skipping multi-part
    /// splits and vision projector files.
    func resolveGGUFFile(repo: String) async throws -> (path: String, size: Int64) {
        let candidates = try await fetchGGUFCandidates(repo: repo)
        let preferences = ["q4_k_m", "q4_k_s", "q4_0", "q5_k_m", "q8_0"]
        for preference in preferences {
            if let match = candidates.first(where: { $0.path.lowercased().contains(preference) }) {
                return (match.path, match.size)
            }
        }
        let smallest = candidates.min { $0.size < $1.size }!
        return (smallest.path, smallest.size)
    }

    nonisolated private static func quantLabel(from path: String) -> String {
        let lower = path.lowercased()
        for quant in ["q4_k_m", "q4_k_s", "q4_0", "q5_k_m", "q8_0", "q3_k_m", "q2_k"] where lower.contains(quant) {
            return quant.uppercased()
        }
        return ""
    }

    /// Delegate-based download so we get byte-level progress (the async
    /// `download(from:)` API offers none) without a per-byte async loop.
    private static func downloadFile(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        final class Delegate: NSObject, URLSessionDownloadDelegate {
            let destination: URL
            let expectedSize: Int64
            let onProgress: @Sendable (Double) -> Void
            var continuation: CheckedContinuation<Void, Error>?
            private var lastReported = -1

            init(destination: URL, expectedSize: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
                self.destination = destination
                self.expectedSize = expectedSize
                self.onProgress = onProgress
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                            totalBytesExpectedToWrite: Int64) {
                let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
                guard total > 0 else { return }
                let percent = Int(Double(totalBytesWritten) / Double(total) * 100)
                if percent != lastReported {
                    lastReported = percent
                    onProgress(min(1, Double(totalBytesWritten) / Double(total)))
                }
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didFinishDownloadingTo location: URL) {
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                } catch {
                    continuation?.resume(throwing: error)
                    continuation = nil
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if let error {
                    continuation?.resume(throwing: error)
                } else {
                    continuation?.resume()
                }
                continuation = nil
            }
        }

        let delegate = Delegate(destination: destination, expectedSize: expectedSize, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        let task = session.downloadTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Curated Ollama picks

    struct CuratedOllamaModel: Identifiable {
        let name: String
        let blurb: String
        let approxSize: String
        /// The real download size in bytes (from the model's own registry
        /// manifest, not an estimate) — feeds `ModelFitEstimator` so the fit
        /// badge is judged against the exact bytes, not a re-parsed string.
        let sizeBytes: Int64
        /// The company that actually trained/released this specific model —
        /// hand-assigned per entry rather than guessed from the name at
        /// render time, since name-based heuristics have real false
        /// positives here (e.g. "tinyllama" isn't Meta's despite containing
        /// "llama"; "mixtral"/"codestral"/"devstral" are Mistral AI's own
        /// models despite not containing the substring "mistral"). `nil`
        /// means no single company can be honestly credited — a community
        /// fine-tune or research-group release (e.g. LLaVA, Vicuna) — shown
        /// with a neutral icon rather than misattributed to anyone.
        let brand: ProviderBrand?
        let category: String
        var id: String { name }
    }

    /// Both the category order and the model list itself are loaded from a
    /// bundled JSON file (`CuratedOllamaModels.json`) rather than hardcoded
    /// here — this is the part of the catalog that changes weekly as new
    /// models ship, so it shouldn't need a rebuild. `ProviderBrand` itself
    /// stays a Swift enum (compile-time exhaustive switches for anything
    /// brand-identity-related — logo, color, fallback icon — are worth
    /// keeping; new *companies* are rare enough that a Swift case is fine).
    /// Loaded once, lazily, via `static let`'s normal thread-safe semantics;
    /// `AppDelegate.applicationDidFinishLaunching` also touches this
    /// eagerly so a bad entry fails loudly at launch rather than whenever a
    /// user first happens to open the Models tab.
    private static let curatedCatalog = CuratedOllamaCatalog.loadOrFail()

    static var curatedCategoryOrder: [String] { curatedCatalog.categoryOrder }
    static var curatedOllamaModels: [CuratedOllamaModel] { curatedCatalog.models }

    /// Best-effort brand detection for a model name/repo that isn't in the
    /// hand-curated list above — a Hugging Face repo path, a manually typed
    /// Ollama name, or an already-downloaded model. If the name resolves
    /// exactly to a curated entry, that entry's hand-checked `brand` is used
    /// instead of guessing. Otherwise the substring rules below are
    /// deliberately conservative (never guess when unsure) to avoid known
    /// false positives — e.g. "tinyllama"/"vicuna"/"orca-mini" contain
    /// enough of a hint to look Meta/Microsoft-affiliated but genuinely
    /// aren't official releases from those companies.
    static func guessBrand(forName rawName: String) -> ProviderBrand? {
        let name = rawName.lowercased()

        if let curated = curatedOllamaModels.first(where: { $0.name.lowercased() == name }) {
            return curated.brand
        }

        let neverGuess = ["tinyllama", "vicuna", "orca-mini", "wizardlm2-uncensored", "dolphin"]
        if neverGuess.contains(where: { name.contains($0) }) { return nil }

        // Checked before the generic "mistral" substring rule — these are
        // Mistral AI's own models but don't contain that substring.
        if name.contains("mixtral") || name.contains("codestral") || name.contains("devstral") || name.contains("magistral") {
            return .mistral
        }
        if name.contains("mistral") { return .mistral }
        if name.contains("llama") { return .meta }
        if name.contains("qwen") || name.contains("qwq") { return .qwen }
        if name.contains("gemma") || name.contains("gemini") { return .google }
        if name.contains("phi-3") || name.contains("phi-4") || name.contains("phi3") || name.contains("phi4") { return .microsoft }
        if name.contains("deepseek") { return .deepSeek }
        if name.contains("claude") { return .anthropic }
        if name.contains("gpt") { return .openAI }
        if name.contains("grok") { return .xAI }
        if name.contains("command-r") || name.contains("aya-") { return .cohere }
        if name.contains("granite") { return .ibm }
        if name.contains("falcon") { return .tii }
        if name.contains("olmo") { return .allenAI }
        if name.contains("exaone") { return .lg }
        if name.contains("solar") { return .upstage }
        if name.contains("stablelm") || name.contains("stable-code") { return .stabilityAI }
        if name.contains("nemotron") { return .nvidia }
        if name.contains("hermes") { return .nous }
        if name.contains("dbrx") { return .databricks }
        if name.contains("yi-") { return .zeroOneAI }
        if name.contains("ernie") { return .baidu }
        if name.contains("doubao") || name.contains("bytedance") { return .byteDance }

        return nil
    }

    /// Whether an Ollama-library name (with or without a tag) is already
    /// pulled locally.
    func isOllamaModelInstalled(_ name: String) -> Bool {
        let target = name.contains(":") ? name : name + ":latest"
        return ollamaModels.contains { $0.requestModelId == target || $0.requestModelId == name }
    }

    func installedOllamaModelId(_ name: String) -> String? {
        let target = name.contains(":") ? name : name + ":latest"
        return ollamaModels.first { $0.requestModelId == target || $0.requestModelId == name }?.id
    }

    /// The library page shows per-row progress; this tracks which model the
    /// single in-flight pull belongs to.
    private(set) var pullingModelName: String?

    // MARK: User models (llama.cpp / MLX)

    func addUserModel(backend: LocalBackend, source: String, isFile: Bool) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let prefix = backend == .llamaCpp ? "llamacpp" : "mlx"
        let record = LocalModelRecord(
            id: "\(prefix):\(trimmed)",
            requestModelId: trimmed,
            backend: backend,
            displayName: isFile ? (trimmed as NSString).lastPathComponent : trimmed,
            detail: isFile ? "GGUF file on this Mac" : "Hugging Face — downloads on first chat",
            source: trimmed,
            isFile: isFile
        )
        guard !userModels.contains(where: { $0.id == record.id }) else { return }
        userModels.append(record)
        persistUserModels()
    }

    func removeUserModel(id: String) {
        // Delete the file too, but ONLY if it lives in our own managed
        // downloads folder — never a file the user picked from elsewhere.
        if let record = userModels.first(where: { $0.id == id }),
           record.isFile == true,
           let source = record.source, source.hasPrefix(Self.managedModelsDirectory.path) {
            try? FileManager.default.removeItem(atPath: source)
        }
        userModels.removeAll { $0.id == id }
        if activeSpawned?.modelId == id { stopSpawnedServer() }
        persistUserModels()
    }

    private func loadUserModels() {
        guard let data = UserDefaults.standard.data(forKey: Self.userModelsKey),
              let decoded = try? JSONDecoder().decode([LocalModelRecord].self, from: data) else { return }
        userModels = decoded
    }

    private func persistUserModels() {
        if let encoded = try? JSONEncoder().encode(userModels) {
            UserDefaults.standard.set(encoded, forKey: Self.userModelsKey)
        }
    }

    // MARK: Catalog integration

    var allLocalModels: [LocalModelRecord] { ollamaModels + userModels }

    /// Stand-in `APIModel`s so local models flow through the same picker and
    /// chat plumbing as everything else.
    var syntheticModels: [APIModel] {
        allLocalModels.map { APIModel(id: $0.id, name: $0.displayName, type: "text", tier: nil) }
    }

    func record(withId id: String) -> LocalModelRecord? {
        allLocalModels.first { $0.id == id }
    }

    func owns(_ id: String) -> Bool {
        record(withId: id) != nil
    }

    // MARK: Readiness / server lifecycle

    /// Makes sure the backend serving this model is up, starting it if
    /// needed, and returns the OpenAI-compatible base URL to chat against.
    func ensureReady(for record: LocalModelRecord) async throws -> URL {
        switch record.backend {
        case .ollama:
            if await fetchOllamaTags() != nil {
                ollamaReachable = true
                return LocalBackend.ollama.baseURL
            }
            guard installed.contains(.ollama) else {
                throw LocalAIError.notInstalled(.ollama)
            }
            startupStatus = "Starting Ollama…"
            defer { startupStatus = nil }
            guard startManagedOllamaServe() else {
                throw LocalAIError.startFailed(.ollama, "couldn't launch `ollama serve`")
            }
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 700_000_000)
                if await fetchOllamaTags() != nil {
                    ollamaReachable = true
                    Task { await refreshOllamaModels() }
                    return LocalBackend.ollama.baseURL
                }
            }
            throw LocalAIError.startFailed(.ollama, "the server didn't come up — try running `ollama serve` yourself")

        case .llamaCpp, .mlx:
            if let active = activeSpawned,
               active.modelId == record.id,
               spawnedProcess?.isRunning == true,
               await probeSpawnedReady(record.backend) {
                return record.backend.baseURL
            }
            try await startSpawnedServer(for: record)
            return record.backend.baseURL
        }
    }

    /// Launches `ollama serve` as a managed child when the app itself needs
    /// it. Returns false if the binary can't be found.
    @discardableResult
    func startManagedOllamaServe() -> Bool {
        if managedOllama?.isRunning == true { return true }
        guard let binary = resolveBinary("ollama") else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        attachLog(process, backend: .ollama)
        do {
            try process.run()
            managedOllama = process
            return true
        } catch {
            return false
        }
    }

    private func startSpawnedServer(for record: LocalModelRecord) async throws {
        stopSpawnedServer()
        guard let binary = resolveBinary(record.backend.binaryName) else {
            throw LocalAIError.notInstalled(record.backend)
        }

        isStartingServer = true
        startupStatus = (record.isFile ?? false) || record.backend == .ollama
            ? "Loading \(record.displayName)…"
            : "Starting \(record.backend.displayName) — first run downloads the model, which can take a while…"
        defer {
            isStartingServer = false
            startupStatus = nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        switch record.backend {
        case .llamaCpp:
            let source = record.source ?? ""
            let modelArgs = (record.isFile ?? false) ? ["-m", source] : ["-hf", source]
            process.arguments = modelArgs + ["--port", "\(LocalBackend.llamaCpp.port)", "--host", "127.0.0.1"]
        case .mlx:
            process.arguments = ["--model", record.source ?? "", "--port", "\(LocalBackend.mlx.port)", "--host", "127.0.0.1"]
        case .ollama:
            throw LocalAIError.startFailed(.ollama, "internal: ollama is not a spawned backend")
        }

        var environment = ProcessInfo.processInfo.environment
        let basePath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = basePath + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment

        serverLogs[record.backend] = ""
        attachLog(process, backend: record.backend)

        do {
            try process.run()
        } catch {
            throw LocalAIError.startFailed(record.backend, error.localizedDescription)
        }
        spawnedProcess = process
        activeSpawned = (record.backend, record.id)

        // Poll until the server answers. Generous ceiling because a first
        // run may be downloading gigabytes — the process dying ends the wait
        // immediately with its log tail as the error.
        for _ in 0..<1800 {
            try Task.checkCancellation()
            if !process.isRunning {
                let tail = String((serverLogs[record.backend] ?? "").suffix(400))
                activeSpawned = nil
                throw LocalAIError.startFailed(record.backend, tail.isEmpty ? "the server exited immediately" : tail)
            }
            if await probeSpawnedReady(record.backend) {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        stopSpawnedServer()
        throw LocalAIError.startFailed(record.backend, "timed out waiting for the server to become ready")
    }

    private func probeSpawnedReady(_ backend: LocalBackend) async -> Bool {
        switch backend {
        case .llamaCpp:
            // llama-server: /health returns {"status":"ok"} once the model
            // is loaded (verified live on this machine).
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(backend.port)/health")!)
            request.timeoutInterval = 2
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return String(data: data, encoding: .utf8)?.contains("\"ok\"") == true
        case .mlx:
            // mlx_lm.server loads the model before listening — any HTTP
            // response at all means it's up.
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(backend.port)/v1/models")!)
            request.timeoutInterval = 2
            let result = try? await URLSession.shared.data(for: request)
            return result != nil
        case .ollama:
            return await fetchOllamaTags() != nil
        }
    }

    private func attachLog(_ process: Process, backend: LocalBackend) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                var log = (self.serverLogs[backend] ?? "") + text
                if log.count > 6000 { log = String(log.suffix(6000)) }
                self.serverLogs[backend] = log
                if self.isStartingServer,
                   let lastLine = text.split(separator: "\n").last.map(String.init),
                   !lastLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.startupStatus = String(lastLine.prefix(120))
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                if self.spawnedProcess === process {
                    self.spawnedProcess = nil
                    self.activeSpawned = nil
                }
                if self.managedOllama === process {
                    self.managedOllama = nil
                }
            }
        }
    }

    func stopSpawnedServer() {
        if let process = spawnedProcess, process.isRunning {
            process.terminate()
        }
        spawnedProcess = nil
        activeSpawned = nil
    }

    /// Called on app quit — takes down whatever we started (never an Ollama
    /// server the user was already running themselves).
    func stopAllServers() {
        stopSpawnedServer()
        if let process = managedOllama, process.isRunning {
            process.terminate()
        }
        managedOllama = nil
    }
}

// MARK: - Errors

enum LocalAIError: LocalizedError {
    case notInstalled(LocalBackend)
    case startFailed(LocalBackend, String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let backend):
            return "\(backend.displayName) isn't installed on this Mac. Install it (\(backend.installCommand)) — see Settings → \(backend.displayName)."
        case .startFailed(let backend, let detail):
            return "\(backend.displayName) couldn't start: \(detail)"
        }
    }
}
