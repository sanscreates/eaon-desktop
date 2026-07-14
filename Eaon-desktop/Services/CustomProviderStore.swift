import AppKit
import Foundation

/// Which request/response shape a custom provider's endpoint speaks. Aqua
/// itself is always `.openAICompatible` (that's the shape its own
/// `/chat/completions` already uses) — this only matters for BYOK configs.
enum APIRequestFormat: String, Codable, CaseIterable, Identifiable {
    case openAICompatible
    case anthropicMessages
    case googleGemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "Standard (OpenAI-style)"
        case .anthropicMessages: return "Anthropic (Claude)"
        case .googleGemini: return "Google (Gemini)"
        }
    }

    var helpText: String {
        switch self {
        case .openAICompatible:
            return "The format almost every provider speaks — OpenAI, Mistral, DeepSeek, xAI, Perplexity, NVIDIA, and most others. If you're not sure, this is the one."
        case .anthropicMessages:
            return "Only for connecting straight to Anthropic with an Anthropic API key."
        case .googleGemini:
            return "Only for connecting straight to Google with a Gemini API key."
        }
    }
}

/// One user-configured, bring-your-own-key endpoint — bypasses Aqua entirely
/// for whichever models it lists. There's no discovery call for these (unlike
/// Aqua's own catalog), so the user has to know the exact model IDs their key
/// grants access to.
struct CustomProviderConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var brand: ProviderBrand
    var baseURL: String
    var format: APIRequestFormat
    var modelIDs: [String]
    var createdAt = Date()
    /// User-chosen label for this connection — e.g. "Eaon" for a gateway
    /// that happens to speak OpenAI's wire format. Optional and nil by
    /// default (old saved configs decode fine without it); `displayName`
    /// is what every user-facing surface should show, never `brand`
    /// directly, so a renamed connection shows its real name everywhere
    /// at once — the model picker, its sidebar row, error messages.
    var customName: String?

    /// File name of a user-picked logo image stored via `ProviderLogoStore`
    /// — nil (the default, decodes fine on old saved configs) falls back to
    /// `brand`'s catalog logo. An escape hatch for the common case where
    /// `brand` is really "closest wire-format match," not the actual
    /// company this connection points at.
    var customLogoFileName: String?

    var trimmedModelIDs: [String] {
        modelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// What to actually call this connection anywhere it's shown to the
    /// user — the custom name if one is set, the underlying brand's name
    /// otherwise. `brand.companyName` itself stays reserved for text
    /// that's specifically about the real service (e.g. "get your key
    /// from OpenAI's dashboard"), which stays true regardless of what the
    /// user named the connection.
    var displayName: String {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? brand.companyName : trimmed
    }
}

/// A starting point for the add-provider form — filled in only where the
/// real, public base URL and wire format are well known and stable. Left out
/// entirely for brands whose real API is regional/workspace-specific
/// (Databricks, IBM watsonx), uses a non-bearer auth flow this app doesn't
/// implement (Baidu's access-token exchange, Amazon Bedrock's SigV4), or
/// isn't confidently known — the user fills those in themselves.
enum KnownProviderDefaults {
    static func baseURL(for brand: ProviderBrand) -> String? {
        switch brand {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .mistral: return "https://api.mistral.ai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .perplexity: return "https://api.perplexity.ai"
        case .nvidia: return "https://integrate.api.nvidia.com/v1"
        case .cohere: return "https://api.cohere.ai/compatibility/v1"
        case .zeroOneAI: return "https://api.01.ai/v1"
        case .reka: return "https://api.reka.ai/v1"
        // Hosting/aggregator APIs, not model makers — both OpenAI-compatible
        // and confirmed live (2026-07-07).
        case .groq: return "https://api.groq.com/openai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        // Same category as groq/openRouter — OpenAI-compatible, confirmed
        // against each provider's own docs (2026-07-12).
        case .together: return "https://api.together.ai/v1"
        case .fireworks: return "https://api.fireworks.ai/inference/v1"
        case .cerebras: return "https://api.cerebras.ai/v1"
        default: return nil
        }
    }

    static func format(for brand: ProviderBrand) -> APIRequestFormat {
        switch brand {
        case .anthropic: return .anthropicMessages
        case .google: return .googleGemini
        default: return .openAICompatible
        }
    }

    /// Every auto-fillable URL — lets the form tell "still the auto-filled
    /// value" apart from "the user typed their own" when brands change.
    static var allKnownBaseURLs: Set<String> {
        Set(ProviderBrand.allCases.compactMap { baseURL(for: $0) })
    }

    /// A real example model ID, so people who've never heard the term
    /// "model ID" can see what one looks like for their chosen provider.
    static func exampleModelID(for brand: ProviderBrand) -> String? {
        switch brand {
        case .openAI: return "gpt-4o"
        case .anthropic: return "claude-sonnet-4-5"
        case .google: return "gemini-2.5-flash"
        case .mistral: return "mistral-large-latest"
        case .deepSeek: return "deepseek-chat"
        case .xAI: return "grok-4"
        case .perplexity: return "sonar-pro"
        case .nvidia: return "meta/llama-3.3-70b-instruct"
        case .cohere: return "command-a-03-2025"
        // Both confirmed live against the real, public API (2026-07-07).
        case .groq: return "llama-3.3-70b-versatile"
        case .openRouter: return "anthropic/claude-sonnet-5"
        // All three confirmed against each provider's own docs (2026-07-12).
        case .together: return "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        case .fireworks: return "accounts/fireworks/models/llama-v3p1-8b-instruct"
        case .cerebras: return "llama3.1-8b"
        default: return nil
        }
    }
}

@MainActor
@Observable
final class CustomProviderStore {
    static let shared = CustomProviderStore()

    private let storageKey = "aqua_custom_providers"
    private(set) var configs: [CustomProviderConfig] = []

    /// modelId → owning config id, rebuilt on every mutation of `configs`.
    /// `config(owning:)` is called per model, per `chatModels` evaluation,
    /// per frame — a live CPU sample showed the old linear scan (which
    /// re-TRIMMED every config's model-id list on every single call) as a
    /// top frame in the sustained full-core burn. A stored dictionary keeps
    /// this observable (views reading it still register a dependency, since
    /// it's a tracked property mutated alongside `configs`) while making
    /// the hot lookup O(1) with zero allocation.
    private var ownerByModelId: [String: UUID] = [:]

    private init() {
        load()
        rebuildOwnerIndex()
    }

    var sortedConfigs: [CustomProviderConfig] {
        configs.sorted { $0.createdAt < $1.createdAt }
    }

    /// The config (if any) that lists a given model id as its own — first
    /// match wins if a user somehow duplicates an id across two configs
    /// (preserved by `rebuildOwnerIndex` keeping the first writer of a key).
    func config(owning modelId: String) -> CustomProviderConfig? {
        guard let ownerId = ownerByModelId[modelId] else { return nil }
        return configs.first { $0.id == ownerId }
    }

    private func rebuildOwnerIndex() {
        var index: [String: UUID] = [:]
        for config in configs {
            for modelId in config.trimmedModelIDs where index[modelId] == nil {
                index[modelId] = config.id
            }
        }
        ownerByModelId = index
    }

    func apiKey(for configId: UUID) -> String? {
        APIKeyStore.loadAPIKey(forAccount: keychainAccount(for: configId))
    }

    func save(_ config: CustomProviderConfig, apiKey: String) throws {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        rebuildOwnerIndex()
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            try APIKeyStore.saveAPIKey(trimmedKey, forAccount: keychainAccount(for: config.id))
        }
        persist()
    }

    func remove(_ id: UUID) {
        if let fileName = configs.first(where: { $0.id == id })?.customLogoFileName {
            ProviderLogoStore.deleteLogo(fileName: fileName)
        }
        configs.removeAll { $0.id == id }
        rebuildOwnerIndex()
        APIKeyStore.deleteAPIKey(forAccount: keychainAccount(for: id))
        persist()
    }

    /// `fileName` nil resets to the brand's default catalog logo, deleting
    /// whatever custom image was on disk for this connection.
    func setCustomLogo(fileName: String?, for configId: UUID) {
        guard let index = configs.firstIndex(where: { $0.id == configId }) else { return }
        configs[index].customLogoFileName = fileName
        persist()
    }

    func logoImage(for config: CustomProviderConfig) -> NSImage? {
        guard let fileName = config.customLogoFileName else { return nil }
        return ProviderLogoStore.image(fileName: fileName)
    }

    /// Synthetic catalog entries for every configured custom model, shaped
    /// like `APIModel` so they can merge into the same list the picker and
    /// chat pipeline already work with.
    var syntheticModels: [APIModel] {
        configs.flatMap { config in
            config.trimmedModelIDs.map { modelId in
                APIModel(id: modelId, name: nil, type: "text", tier: nil)
            }
        }
    }

    private func keychainAccount(for id: UUID) -> String {
        "custom-provider-\(id.uuidString)"
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CustomProviderConfig].self, from: data) else { return }
        configs = decoded
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
