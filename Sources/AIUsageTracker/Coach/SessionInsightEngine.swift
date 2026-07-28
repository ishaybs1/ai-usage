import Foundation

// MARK: - Session insights
//
// Produces 3 concrete tips per expensive session using local transcript rules only.
//
// We intentionally do NOT spawn Claude Code / Cursor Agent from the menu-bar app:
// those child processes probe the filesystem (Desktop, Music, …) and macOS attributes
// the TCC permission sheets to AIUsageTracker as the responsible parent.

enum SessionInsightEngine {

    struct Outcome: Equatable {
        var tipsBySessionId: [String: [String]]
        /// Shown in the report so users know what produced the advice.
        var sourceLabel: String
    }

    /// Build 3 tips for each session.
    static func insights(for sessions: [SessionCost]) -> Outcome {
        var map: [String: [String]] = [:]
        for s in sessions {
            let signals = TranscriptSignalsLoader.load(sessionKey: s.id)
            map[s.id] = CoachAdvisor.coachingTips(for: s, signals: signals, limit: 3)
        }
        return Outcome(
            tipsBySessionId: map,
            sourceLabel: "local transcript rules (no LLM subprocess — avoids macOS folder permission prompts)"
        )
    }
}
