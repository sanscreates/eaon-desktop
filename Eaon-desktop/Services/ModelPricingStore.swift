import Foundation

/// Approximate cost-per-1K output tokens in USD, based on Aqua tier classification.
/// These are estimates; update when Aqua publishes official pricing.
enum ModelPricingStore {
    // Cost per 1,000 output tokens in USD
    private static let premiumCostPer1K: Double = 0.015   // ~$15 / 1M
    private static let standardCostPer1K: Double = 0.005  // ~$5 / 1M
    private static let freeCostPer1K: Double = 0.0

    // Per-model overrides where we have known pricing
    private static let overrides: [String: Double] = [
        "gpt-5.5":          0.020,
        "opus-4.8":         0.018,
        "opus-4.7":         0.018,
        "opus-4.6":         0.015,
        "grok-4.3":         0.012,
        "gemini-3.1-pro":   0.010,
        "gemini-3-pro":     0.010,
        "sonnet-4.6":       0.009,
        "sonnet-4.5":       0.008,
        "haiku-4.5":        0.003,
        "deepseek-v4-pro":  0.008,
        "gpt-5.4":          0.006,
        "gpt-5.4-mini":     0.002,
        "gpt-5.4-nano":     0.001,
    ]

    static func costPer1KTokens(for modelId: String, tier: String?) -> Double {
        if let price = overrides[modelId] { return price }
        switch tier?.lowercased() {
        case "premium": return premiumCostPer1K
        case "free":    return freeCostPer1K
        default:        return standardCostPer1K
        }
    }

    /// Estimated cost in USD for a given token count.
    static func estimatedCost(tokens: Int, modelId: String, tier: String?) -> Double {
        let rate = costPer1KTokens(for: modelId, tier: tier)
        return (Double(tokens) / 1000.0) * rate
    }

    static func formatCost(_ usd: Double) -> String {
        if usd < 0.0001 { return "< $0.0001" }
        if usd < 0.01   { return String(format: "$%.4f", usd) }
        return String(format: "$%.3f", usd)
    }
}
