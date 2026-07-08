import Foundation

// MARK: - Token pricing
//
// Anthropic API rates (USD per 1M tokens). Used to turn local session token counts into
// dollar estimates. Unknown / unmapped Cursor models fall back to Haiku (cheapest).

struct TokenUsage: Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite5m: Int = 0
    var cacheWrite1h: Int = 0

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h
        )
    }
}

struct ModelRates {
    let inputPerM: Double
    let outputPerM: Double
    let cacheReadPerM: Double
    let cacheWrite5mPerM: Double
    let cacheWrite1hPerM: Double

    func cost(for usage: TokenUsage) -> Double {
        let m = 1_000_000.0
        let raw = Double(usage.input) * inputPerM / m
            + Double(usage.output) * outputPerM / m
            + Double(usage.cacheRead) * cacheReadPerM / m
            + Double(usage.cacheWrite5m) * cacheWrite5mPerM / m
            + Double(usage.cacheWrite1h) * cacheWrite1hPerM / m
        return (raw * 100).rounded() / 100
    }
}

enum TokenPricing {
    /// Cursor aliases like "default" / "composer-*" map here (user preference: Sonnet).
    static let cursorDefaultModel = "claude-sonnet-4-6"
    static let cheapestModel = "claude-haiku-4-5"

    private static let rates: [String: ModelRates] = [
        "claude-haiku-4-5": ModelRates(inputPerM: 1, outputPerM: 5,
                                         cacheReadPerM: 0.10, cacheWrite5mPerM: 1.25, cacheWrite1hPerM: 2),
        "claude-haiku-4-5-20251001": ModelRates(inputPerM: 1, outputPerM: 5,
                                                 cacheReadPerM: 0.10, cacheWrite5mPerM: 1.25, cacheWrite1hPerM: 2),
        "claude-sonnet-4-6": ModelRates(inputPerM: 3, outputPerM: 15,
                                         cacheReadPerM: 0.30, cacheWrite5mPerM: 3.75, cacheWrite1hPerM: 6),
        "claude-sonnet-4": ModelRates(inputPerM: 3, outputPerM: 15,
                                       cacheReadPerM: 0.30, cacheWrite5mPerM: 3.75, cacheWrite1hPerM: 6),
        // Opus 4.8 list price: $5 / $25 per 1M (cache read 0.1×, write-5m 1.25×, write-1h 2×).
        "claude-opus-4-8": ModelRates(inputPerM: 5, outputPerM: 25,
                                       cacheReadPerM: 0.50, cacheWrite5mPerM: 6.25, cacheWrite1hPerM: 10),
        "claude-opus-4": ModelRates(inputPerM: 5, outputPerM: 25,
                                     cacheReadPerM: 0.50, cacheWrite5mPerM: 6.25, cacheWrite1hPerM: 10),
        "composer-2.5": ModelRates(inputPerM: 1, outputPerM: 5,
                                    cacheReadPerM: 0.10, cacheWrite5mPerM: 1.25, cacheWrite1hPerM: 2),
    ]

    static func normalize(_ raw: String) -> String {
        let m = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty || m == "default" || m == "<synthetic>" { return cursorDefaultModel }
        if m.hasPrefix("composer") { return cursorDefaultModel }
        if m.contains("haiku") { return "claude-haiku-4-5" }
        if m.contains("sonnet") { return "claude-sonnet-4-6" }
        if m.contains("opus") { return "claude-opus-4-8" }
        return m
    }

    static func rates(for model: String) -> ModelRates {
        let key = normalize(model)
        if let r = rates[key] { return r }
        // Unknown model → cheapest tier.
        return rates[cheapestModel]!
    }

    static func cost(model: String, usage: TokenUsage) -> Double {
        rates(for: model).cost(for: usage)
    }
}
