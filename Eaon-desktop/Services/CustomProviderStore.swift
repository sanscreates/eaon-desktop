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

    var trimmedModelIDs: [String] {
        modelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    private init() {
        load()
    }

    var sortedConfigs: [CustomProviderConfig] {
        configs.sorted { $0.createdAt < $1.createdAt }
    }

    /// The config (if any) that lists a given model id as its own — first
    /// match wins if a user somehow duplicates an id across two configs.
    func config(owning modelId: String) -> CustomProviderConfig? {
        configs.first { $0.trimmedModelIDs.contains(modelId) }
    }

    func apiKey(for configId: UUID) -> String? {
        KeychainService.loadAPIKey(forAccount: keychainAccount(for: configId))
    }

    func save(_ config: CustomProviderConfig, apiKey: String) throws {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            try KeychainService.saveAPIKey(trimmedKey, forAccount: keychainAccount(for: config.id))
        }
        persist()
    }

    func remove(_ id: UUID) {
        configs.removeAll { $0.id == id }
        KeychainService.deleteAPIKey(forAccount: keychainAccount(for: id))
        persist()
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
