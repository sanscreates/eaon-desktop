import SwiftUI

enum ProviderBrand: String, Hashable, Codable, CaseIterable {
    case openAI
    case anthropic
    case google
    case deepSeek
    case xAI
    case meta
    case mistral
    case qwen
    case zhipu
    case kimi
    case miniMax
    case mimo
    case nvidia
    case perplexity
    case stepFun
    case nous
    case amazon
    case aqua
    case inceptionLabs
    case cohere
    case ai21
    case databricks
    case reka
    case writer
    case zeroOneAI
    case ibm
    case liquidAI
    case baidu
    case byteDance
    case microsoft
    case stabilityAI
    case tii
    case allenAI
    case lg
    case intel
    case upstage
    /// Not a model *maker* — a hosting/aggregator API that serves other
    /// companies' (mostly open-source) models fast. Exists in this enum only
    /// as a BYOK connection option, never as a `brand(for:)` classification
    /// target — a model it serves is still "made by" whoever actually
    /// trained it (Meta, Alibaba, etc.), not by Groq.
    case groq
    /// Same distinction as `groq` — a gateway to hundreds of other
    /// companies' models via one key, not a model maker itself.
    case openRouter

    /// The curated set offered when adding a bring-your-own-key connection —
    /// deliberately not `allCases`. That full list also carries every brand
    /// Aqua's own live catalog needs for correct model classification and
    /// logos (Zhipu, StepFun, Nous Research, TII, and other real but niche
    /// labs), which would make a "pick your provider" picker for BYOK mostly
    /// noise: almost nobody keeps a personal API key for those. This list is
    /// just the companies/gateways a typical person would actually have a
    /// key for. `aqua` is deliberately excluded — it's the app's own default
    /// backend, not something you bring a key for.
    static let byokPickerBrands: [ProviderBrand] = [
        .openAI, .anthropic, .google, .meta, .mistral, .deepSeek, .xAI,
        .groq, .openRouter, .perplexity, .cohere, .nvidia,
    ]

    var companyName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        case .deepSeek: return "DeepSeek"
        case .xAI: return "xAI"
        case .meta: return "Meta"
        case .mistral: return "Mistral"
        case .qwen: return "Qwen"
        case .zhipu: return "Zhipu AI"
        case .kimi: return "Moonshot"
        case .miniMax: return "MiniMax"
        case .mimo: return "Xiaomi"
        case .nvidia: return "NVIDIA"
        case .perplexity: return "Perplexity"
        case .stepFun: return "StepFun"
        case .nous: return "Nous Research"
        case .amazon: return "Amazon"
        case .aqua: return "Aqua"
        case .inceptionLabs: return "Inception Labs"
        case .cohere: return "Cohere"
        case .ai21: return "AI21 Labs"
        case .databricks: return "Databricks"
        case .reka: return "Reka AI"
        case .writer: return "Writer"
        case .zeroOneAI: return "01.AI"
        case .ibm: return "IBM"
        case .liquidAI: return "Liquid AI"
        case .baidu: return "Baidu"
        case .byteDance: return "ByteDance"
        case .microsoft: return "Microsoft"
        case .stabilityAI: return "Stability AI"
        case .tii: return "TII"
        case .allenAI: return "Allen Institute for AI"
        case .lg: return "LG"
        case .intel: return "Intel"
        case .upstage: return "Upstage"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        }
    }

    func logoAssetName(for colorScheme: ColorScheme) -> String? {
        switch self {
        case .openAI:
            return colorScheme == .dark ? "openai-dark" : "openai-light"
        case .anthropic:
            return colorScheme == .dark ? "anthropic-dark" : "anthropic-light"
        case .xAI:
            return colorScheme == .dark ? "xai-dark" : "xai-light"
        case .zhipu:
            return colorScheme == .dark ? "zhipu-dark" : "zhipu-light"
        case .kimi:
            return colorScheme == .dark ? "kimi-dark" : "kimi-light"
        case .google: return "google"
        case .deepSeek: return "deepseek"
        case .meta: return "meta"
        case .mistral: return "mistral"
        case .qwen: return "qwen"
        case .miniMax: return "minimax"
        case .mimo: return "xiaomi"
        case .nvidia: return "nvidia"
        case .perplexity: return "perplexity"
        case .stepFun: return "stepfun"
        case .databricks: return "databricks"
        case .baidu: return "baidu"
        case .byteDance: return "bytedance"
        case .lg: return "lg"
        case .intel: return "intel"
        case .ibm: return "ibm"
        case .inceptionLabs: return "inception"
        case .nous: return "nousresearch"
        case .microsoft: return "microsoft"
        case .stabilityAI: return "stability"
        case .tii: return "tii"
        case .zeroOneAI: return "zeroone"
        case .openRouter: return "openrouter"
        case .amazon, .aqua, .cohere, .ai21, .reka, .writer, .liquidAI, .allenAI, .upstage, .groq:
            // No real, permissively-licensed public mark found for these —
            // verified against simple-icons' full catalog (2026-07-06)
            // rather than assumed (Microsoft and IBM were notable exclusions
            // there, most likely deliberate on their part — both now covered
            // above from a different source). The SF Symbol +
            // accent-color fallback below is the honest answer for a brand
            // with no available logo, not a placeholder to revisit later.
            return nil
        }
    }

    var fallbackIcon: String {
        switch self {
        case .openAI: return "sparkles"
        case .anthropic: return "a.circle.fill"
        case .google: return "g.circle.fill"
        case .deepSeek: return "drop.triangle.fill"
        case .xAI: return "xmark"
        case .meta: return "infinity"
        case .mistral: return "wind"
        case .qwen: return "q.circle.fill"
        case .zhipu: return "z.circle.fill"
        case .kimi: return "moon.fill"
        case .miniMax: return "waveform"
        case .mimo: return "hexagon.fill"
        case .nvidia: return "n.circle.fill"
        case .perplexity: return "dot.scope"
        case .stepFun: return "stairs"
        case .nous: return "hare.fill"
        case .amazon: return "a.square.fill"
        case .aqua: return "drop.fill"
        case .inceptionLabs: return "m.circle.fill"
        case .cohere: return "c.circle.fill"
        case .ai21: return "j.circle.fill"
        case .databricks: return "d.circle.fill"
        case .reka: return "r.circle.fill"
        case .writer: return "pencil.circle.fill"
        case .zeroOneAI: return "y.circle.fill"
        case .ibm: return "i.circle.fill"
        case .liquidAI: return "drop.circle.fill"
        case .baidu: return "b.circle.fill"
        case .byteDance: return "bolt.circle.fill"
        case .microsoft: return "m.square.fill"
        case .stabilityAI: return "s.circle.fill"
        case .tii: return "t.circle.fill"
        case .allenAI: return "graduationcap.fill"
        case .lg: return "l.circle.fill"
        case .intel: return "cpu"
        case .upstage: return "u.circle.fill"
        case .groq: return "bolt.fill"
        case .openRouter: return "arrow.triangle.branch"
        }
    }

    var accentColor: Color {
        switch self {
        case .openAI: return Color(hex: "#10A37F")
        case .anthropic: return Color(hex: "#D97757")
        case .google: return Color(hex: "#4285F4")
        case .deepSeek: return Color(hex: "#4D6BFE")
        case .xAI: return Color(hex: "#FFFFFF")
        case .meta: return Color(hex: "#0668E1")
        case .mistral: return Color(hex: "#F7D046")
        case .qwen: return Color(hex: "#615EFF")
        case .zhipu: return Color(hex: "#3366FF")
        case .kimi: return Color(hex: "#7C5CFC")
        case .miniMax: return Color(hex: "#FF6B6B")
        case .mimo: return Color(hex: "#FF6900")
        case .nvidia: return Color(hex: "#76B900")
        case .perplexity: return Color(hex: "#20B8CD")
        case .stepFun: return Color(hex: "#22D3EE")
        // Corrected 2026-07-07: Nous Research's real public brand is
        // monochrome black/white, not purple — a neutral tone is more
        // honest than a specific hue they don't actually use.
        case .nous: return Color(hex: "#D4D4D8")
        case .amazon: return Color(hex: "#FF9900")
        case .aqua: return Color(hex: "#2DD4BF")
        // Confirmed 2026-07-07: Inception Labs' real public branding is also
        // monochrome — this neutral tone (picked before that was confirmed)
        // already matched.
        case .inceptionLabs: return Color(hex: "#94A3B8")
        // Corrected 2026-07-07 — real brand color is a dark forest green,
        // not pink:
        case .cohere: return Color(hex: "#39594D")
        // Corrected 2026-07-07 — real brand color is pink/magenta, not amber:
        case .ai21: return Color(hex: "#E91E63")
        case .databricks: return Color(hex: "#FF3621")
        case .reka: return Color(hex: "#F43F5E")
        case .writer: return Color(hex: "#B45309")
        // Updated 2026-07-07 to match the real logo's own accent dot now
        // that a real asset is bundled (was a lightened stand-in guess
        // before that asset existed).
        case .zeroOneAI: return Color(hex: "#00FF25")
        case .ibm: return Color(hex: "#0F62FE")
        // Corrected 2026-07-07: Liquid AI's real public branding is also
        // monochrome black/white, not blue.
        case .liquidAI: return Color(hex: "#CBD5E1")
        case .baidu: return Color(hex: "#2932E1")
        // Corrected 2026-07-06: the old value (#FE2C55) was TikTok's pink —
        // TikTok is a ByteDance product, not ByteDance's own brand color.
        // #3C8CFF is ByteDance's actual verified corporate color.
        case .byteDance: return Color(hex: "#3C8CFF")
        // Verified official color (simple-icons, 2026-07-06):
        case .lg: return Color(hex: "#A50034")
        // Verified official color (simple-icons, 2026-07-06):
        case .intel: return Color(hex: "#0071C5")
        // Microsoft's is its well-known public corporate blue (no logo
        // asset for this one — see logoAssetName's note on why).
        case .microsoft: return Color(hex: "#0078D4")
        // Updated 2026-07-07 to match the real logo's own gradient now that
        // a real asset is bundled (was a darker stand-in guess before).
        case .stabilityAI: return Color(hex: "#9D39FF")
        case .tii: return Color(hex: "#6400FF")
        // allenAI and upstage still have no logo asset — verified real
        // brand colors (2026-07-07), just no permissively-licensed mark
        // found yet; see logoAssetName.
        case .allenAI: return Color(hex: "#F0529C")
        case .upstage: return Color(hex: "#908AF9")
        // Reasonable, distinct placeholder — not a confirmed brand color
        // (no real logo found for Groq either; see logoAssetName).
        case .groq: return Color(hex: "#F55036")
        // Verified official color (simple-icons, 2026-07-07):
        case .openRouter: return Color(hex: "#94A3B8")
        }
    }
}

struct ModelProviderInfo: Hashable {
    let company: String
    let brand: ProviderBrand
    let iconSystemName: String
    let accentColor: Color

    init(brand: ProviderBrand) {
        self.brand = brand
        self.company = brand.companyName
        self.iconSystemName = brand.fallbackIcon
        self.accentColor = brand.accentColor
    }
}

enum ModelCatalog {
    static func brand(for modelId: String) -> ProviderBrand {
        let id = modelId.lowercased()

        if id.hasPrefix("gpt") || id.hasPrefix("gptimage") { return .openAI }
        if id.contains("gemini") || id.contains("gemma") { return .google }
        if id.contains("claude") || id.hasPrefix("haiku") || id.hasPrefix("sonnet") || id.hasPrefix("opus")
            || id.hasPrefix("fable") {
            return .anthropic
        }
        if id.hasPrefix("grok") { return .xAI }
        if id.hasPrefix("nova") { return .amazon }
        if id.contains("deepseek") { return .deepSeek }
        if id.contains("qwen") { return .qwen }
        if id.contains("llama") { return .meta }
        if id.contains("mistral") { return .mistral }
        if id.contains("kimi") { return .kimi }
        if id.contains("glm") { return .zhipu }
        if id.contains("mimo") { return .mimo }
        if id.contains("minimax") { return .miniMax }
        if id.contains("nemotron") { return .nvidia }
        if id.hasPrefix("sonar") { return .perplexity }
        if id.hasPrefix("hermes") { return .nous }
        if id.hasPrefix("step") { return .stepFun }
        if id.hasPrefix("mercury") { return .inceptionLabs }
        if id.hasPrefix("command") { return .cohere }
        if id.contains("jamba") { return .ai21 }
        if id.contains("dbrx") { return .databricks }
        if id.hasPrefix("reka") { return .reka }
        if id.contains("palmyra") { return .writer }
        if id.hasPrefix("yi-") { return .zeroOneAI }
        if id.contains("granite") { return .ibm }
        if id.hasPrefix("lfm") { return .liquidAI }
        if id.contains("ernie") { return .baidu }
        if id.contains("doubao") { return .byteDance }
        if id.hasPrefix("phi") { return .microsoft }
        if id.contains("falcon") { return .tii }
        if id.contains("olmo") { return .allenAI }
        if id.hasPrefix("exaone") { return .lg }
        if id.hasPrefix("solar") { return .upstage }
        if id.contains("stablelm") { return .stabilityAI }

        return .aqua
    }

    static func provider(for modelId: String) -> ModelProviderInfo {
        ModelProviderInfo(brand: brand(for: modelId))
    }

    static func displayName(modelId: String, apiName: String?) -> String {
        AquaSupportedModels.displayName(for: modelId, apiName: apiName)
    }

    static func subtitle(modelId: String, apiName: String?, tier: String?) -> String {
        let provider = provider(for: modelId).company
        if let tier, !tier.isEmpty {
            return "\(provider) · \(tier.capitalized)"
        }
        return provider
    }

    static func supportsVision(for modelId: String) -> Bool {
        let id = modelId.lowercased()

        let textOnly: Set<String> = [
            "gpt-oss",
            "hermes",
            "nemotron",
            "step-3.7",
            "sonar",
            "mistral",
            "mistral-3.5",
            "minimax-m2.7",
            "minimax-m3",
            "gemma-4",
            "gpt-5-nano",
            "llama-3.1",
        ]
        if textOnly.contains(id) { return false }

        if id.hasPrefix("gemini") { return true }
        if id.hasPrefix("gpt-5") || id.hasPrefix("gpt-4") { return true }
        if id.hasPrefix("haiku") || id.hasPrefix("sonnet") || id.hasPrefix("opus") || id.hasPrefix("fable") { return true }
        if id.hasPrefix("grok") { return true }
        if id.contains("qwen") { return true }
        if id.contains("llama-4") { return true }
        if id.contains("glm") { return true }
        if id.contains("kimi") { return true }
        if id.contains("deepseek-v4") { return true }
        if id.hasPrefix("nova") { return true }
        if id.contains("mimo") { return true }

        return false
    }
}
