import Foundation

// MARK: - Display helpers

/// USD formatting for the UI.
enum Money {
    static func string(_ value: Double) -> String { String(format: "$%.2f", value) }
}

/// Turns the API's raw dimension keys into human-friendly labels.
enum Labels {
    /// "claude_code" → "Claude Code", "cowork" → "Cowork".
    static func product(_ key: String) -> String {
        key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    /// "claude-opus-4-8" → "Opus 4.8", "claude-sonnet-4-6" → "Sonnet 4.6".
    static func model(_ key: String) -> String {
        // Cursor model keys are pre-formatted (contain a space); pass them through unchanged.
        if key.contains(" ") { return key }
        var parts = key.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return key }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    /// Cursor uses its own model naming ("claude-4.5-sonnet", "gpt-5.1-codex"). Produce a
    /// clean, spaced label we can also use as a stable dictionary key.
    static func cursorModel(_ raw: String) -> String {
        let tokens = raw.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { t -> String in
                let s = String(t)
                switch s.lowercased() {
                case "gpt": return "GPT"
                default: return s.first?.isNumber == true ? s : s.capitalized
                }
            }
        let result = tokens.joined(separator: " ")
        return result.isEmpty ? raw : result
    }
}
