import Foundation

/// A format-agnostic snapshot of the sampling parameters to send with one
/// request. Every field is optional on purpose: `nil` means "don't send this
/// at all," which is *not* the same as sending a neutral value. Many models —
/// reasoning models especially (o1/o3-style, and anything gated by this app's
/// own thinking toggle) — reject `temperature`/`top_p` outright, and even
/// where accepted, an omitted field lets the model keep its own tuned default
/// instead of being pinned to whatever number a slider happened to sit at.
/// So the app sends a parameter only when the user has explicitly turned it
/// on (see `ModelParametersStore`).
///
/// This is a plain value type (Sendable, no actor) so both the Aqua path
/// (`ChatViewModel.streamCompletion`) and the BYOK/local path
/// (`CustomProviderAPIService`) can translate it into whichever wire format
/// they speak without reaching back into a `@MainActor` singleton from a
/// background context.
struct SamplingParameters: Sendable, Equatable {
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var frequencyPenalty: Double?
    var presencePenalty: Double?

    var isEmpty: Bool {
        temperature == nil && topP == nil && maxTokens == nil
            && frequencyPenalty == nil && presencePenalty == nil
    }

    // MARK: - Per-format translation

    /// OpenAI chat-completions shape — used by the Aqua gateway, BYOK
    /// OpenAI-compatible providers, and every local backend (Ollama /
    /// llama.cpp / MLX all speak this dialect through their OpenAI-compat
    /// endpoint). These five are the standard, widely-honored fields; Top-K /
    /// Repeat-Penalty / Min-P are deliberately not here because they aren't
    /// part of this spec and would be silently ignored on the hosted paths,
    /// which would read as "I set it and nothing happened."
    func openAIFields() -> [String: Any] {
        var fields: [String: Any] = [:]
        if let temperature { fields["temperature"] = temperature }
        if let topP { fields["top_p"] = topP }
        if let maxTokens { fields["max_tokens"] = maxTokens }
        if let frequencyPenalty { fields["frequency_penalty"] = frequencyPenalty }
        if let presencePenalty { fields["presence_penalty"] = presencePenalty }
        return fields
    }

    /// Anthropic Messages shape. Anthropic caps `temperature` at 1.0 (not the
    /// 2.0 OpenAI allows), so it's clamped rather than passed through and
    /// rejected. Anthropic has no frequency/presence penalty, so those are
    /// dropped. `max_tokens` is required on that API and is handled by the
    /// caller (which already sends a default), not here.
    func anthropicFields() -> [String: Any] {
        var fields: [String: Any] = [:]
        if let temperature { fields["temperature"] = min(max(temperature, 0), 1) }
        if let topP { fields["top_p"] = topP }
        return fields
    }

    /// Google Gemini's `generationConfig` object. Gemini allows temperature up
    /// to 2.0, has `topP`/`maxOutputTokens`, and no penalty fields. Returns an
    /// empty dict when nothing is set so the caller can skip the key entirely.
    func geminiGenerationConfig() -> [String: Any] {
        var config: [String: Any] = [:]
        if let temperature { config["temperature"] = temperature }
        if let topP { config["topP"] = topP }
        if let maxTokens { config["maxOutputTokens"] = maxTokens }
        return config
    }

    /// Whether an HTTP error body reads like the server rejecting one of these
    /// sampling fields — used to retry the request once without them rather
    /// than surfacing a broken chat when a user drags a slider and then talks
    /// to a model (e.g. a reasoning model) that refuses the parameter. Only
    /// consulted when parameters were actually sent, and the retry drops them
    /// entirely, so at worst this costs one extra request.
    static func looksLikeRejection(_ message: String) -> Bool {
        let lower = message.lowercased()
        let markers = [
            "temperature", "top_p", "top-p", "max_tokens", "max tokens",
            "frequency_penalty", "presence_penalty", "penalty",
            "unsupported value", "unsupported parameter", "unknown parameter",
            "does not support", "not supported", "unexpected parameter",
        ]
        return markers.contains { lower.contains($0) }
    }
}

/// Persists the user's global model/inference parameters (Settings →
/// Assistant → Model Parameters) and exposes them as a `SamplingParameters`
/// snapshot for the request paths to send.
///
/// Design: one global set, applied to every model, with each parameter
/// independently switchable. Everything defaults **off**, so until the user
/// opts a parameter in, requests are byte-for-byte identical to before this
/// existed — no silent behavior change, and no risk of a default temperature
/// breaking a model that doesn't accept one. (Per-model overrides are a
/// natural future extension — the request paths already take a
/// `SamplingParameters` value, so they'd only need a per-model lookup here.)
@MainActor
@Observable
final class ModelParametersStore {
    static let shared = ModelParametersStore()

    // Sensible values used only when the matching toggle is on. The neutral
    // defaults (top-P 1.0, penalties 0.0) are chosen so flipping a toggle on
    // at its default is a no-op change until the user actually moves it.
    static let defaultTemperature = 0.7
    static let defaultTopP = 1.0
    static let defaultMaxTokens = 2048
    static let defaultFrequencyPenalty = 0.0
    static let defaultPresencePenalty = 0.0

    var temperatureEnabled: Bool { didSet { persist() } }
    var temperature: Double { didSet { persist() } }

    var topPEnabled: Bool { didSet { persist() } }
    var topP: Double { didSet { persist() } }

    var maxTokensEnabled: Bool { didSet { persist() } }
    var maxTokens: Int { didSet { persist() } }

    var frequencyPenaltyEnabled: Bool { didSet { persist() } }
    var frequencyPenalty: Double { didSet { persist() } }

    var presencePenaltyEnabled: Bool { didSet { persist() } }
    var presencePenalty: Double { didSet { persist() } }

    /// The snapshot to actually send — only the parameters currently switched
    /// on, everything else `nil` (omitted from the request).
    var effectiveParameters: SamplingParameters {
        SamplingParameters(
            temperature: temperatureEnabled ? temperature : nil,
            topP: topPEnabled ? topP : nil,
            maxTokens: maxTokensEnabled ? maxTokens : nil,
            frequencyPenalty: frequencyPenaltyEnabled ? frequencyPenalty : nil,
            presencePenalty: presencePenaltyEnabled ? presencePenalty : nil
        )
    }

    var isAllDefault: Bool {
        !temperatureEnabled && !topPEnabled && !maxTokensEnabled
            && !frequencyPenaltyEnabled && !presencePenaltyEnabled
    }

    func resetToDefaults() {
        // Set the backing values first, flags last, and persist once at the
        // end — avoids five separate `didSet` writes mid-reset.
        isRestoring = true
        temperature = Self.defaultTemperature
        topP = Self.defaultTopP
        maxTokens = Self.defaultMaxTokens
        frequencyPenalty = Self.defaultFrequencyPenalty
        presencePenalty = Self.defaultPresencePenalty
        temperatureEnabled = false
        topPEnabled = false
        maxTokensEnabled = false
        frequencyPenaltyEnabled = false
        presencePenaltyEnabled = false
        isRestoring = false
        persist()
    }

    // MARK: - Persistence

    private static let key = "model_parameters_v1"
    private var isRestoring = false

    private init() {
        let defaults = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        temperatureEnabled = defaults["temperatureEnabled"] as? Bool ?? false
        temperature = defaults["temperature"] as? Double ?? Self.defaultTemperature
        topPEnabled = defaults["topPEnabled"] as? Bool ?? false
        topP = defaults["topP"] as? Double ?? Self.defaultTopP
        maxTokensEnabled = defaults["maxTokensEnabled"] as? Bool ?? false
        maxTokens = defaults["maxTokens"] as? Int ?? Self.defaultMaxTokens
        frequencyPenaltyEnabled = defaults["frequencyPenaltyEnabled"] as? Bool ?? false
        frequencyPenalty = defaults["frequencyPenalty"] as? Double ?? Self.defaultFrequencyPenalty
        presencePenaltyEnabled = defaults["presencePenaltyEnabled"] as? Bool ?? false
        presencePenalty = defaults["presencePenalty"] as? Double ?? Self.defaultPresencePenalty
    }

    private func persist() {
        guard !isRestoring else { return }
        UserDefaults.standard.set([
            "temperatureEnabled": temperatureEnabled,
            "temperature": temperature,
            "topPEnabled": topPEnabled,
            "topP": topP,
            "maxTokensEnabled": maxTokensEnabled,
            "maxTokens": maxTokens,
            "frequencyPenaltyEnabled": frequencyPenaltyEnabled,
            "frequencyPenalty": frequencyPenalty,
            "presencePenaltyEnabled": presencePenaltyEnabled,
            "presencePenalty": presencePenalty,
        ], forKey: Self.key)
    }
}
