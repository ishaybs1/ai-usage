import Foundation

// MARK: - Built-in transcript analysis
//
// Ranks expensive local Claude + Cursor sessions, loads transcript signals, asks Sonnet via
// the `claude` CLI when available (else local rules), and writes ~/llm-coach-reports/*.md.

enum TranscriptAnalyzer {

    struct Result: Equatable {
        let reportURL: URL
        let sessionCount: Int
        let totalCost: Double
        let insightSource: String
    }

    enum AnalysisError: LocalizedError {
        case noSessions
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSessions: return "No priced local sessions found yet."
            case .writeFailed(let msg): return msg
            }
        }
    }

    /// Analyze the `limit` most expensive sessions over the last `lookbackDays` and write a report.
    static func run(
        lookbackDays: Int = 7,
        limit: Int = 10,
        reportDirectory: URL = defaultReportDirectory(),
        now: Date = Date()
    ) async throws -> Result {
        await LocalUsageScanner.shared.refresh()
        let sessions = await expensiveSessions(lookbackDays: lookbackDays, limit: min(limit, 5))
        guard !sessions.isEmpty else { throw AnalysisError.noSessions }

        let outcome = SessionInsightEngine.insights(for: sessions)
        let total = sessions.reduce(0.0) { $0 + $1.cost }
        let markdown = render(
            sessions: sessions,
            tipsById: outcome.tipsBySessionId,
            insightSource: outcome.sourceLabel,
            lookbackDays: lookbackDays,
            totalCost: total,
            habitTips: CoachAdvisor.tips(on: now),
            now: now
        )

        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let day = dayFormatter.string(from: now)
        let url = reportDirectory.appendingPathComponent("\(day)-usage-coach.md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw AnalysisError.writeFailed(error.localizedDescription)
        }
        return Result(
            reportURL: url,
            sessionCount: sessions.count,
            totalCost: total,
            insightSource: outcome.sourceLabel
        )
    }

    static func defaultReportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("llm-coach-reports", isDirectory: true)
    }

    // MARK: Session ranking

    /// Merge per-day session slices across the lookback window, then take the top `limit` by cost.
    static func expensiveSessions(lookbackDays: Int, limit: Int) async -> [SessionCost] {
        let latestKey = await LocalUsageScanner.shared.latestAvailableDayKey()
        guard let latest = LocalUsageScanner.parseDay(latestKey) else { return [] }
        let cal = Calendar.analytics

        struct Acc {
            var tool: String
            var cost: Double = 0
            var messages: Int = 0
            var byModel: [String: Double] = [:]
            var title: String
        }
        var merged: [String: Acc] = [:]

        for offset in 0..<max(lookbackDays, 1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: latest) else { continue }
            let key = LocalUsageScanner.dayKey(day)
            let agg = await LocalUsageScanner.shared.aggregate(for: key)
            for (sessionKey, s) in agg.sessions where s.cost > 0 {
                var a = merged[sessionKey] ?? Acc(tool: s.tool, title: s.title ?? "")
                a.cost = ((a.cost + s.cost) * 100).rounded() / 100
                a.messages += s.messages
                for (m, c) in s.byModel { a.byModel[m, default: 0] += c }
                if a.title.isEmpty, let t = s.title { a.title = t }
                merged[sessionKey] = a
            }
        }

        return merged
            .map { key, a -> SessionCost in
                let dominant = a.byModel.max { $0.value < $1.value }?.key ?? ""
                let idPart = key.split(separator: ":").dropFirst().joined(separator: ":")
                let fallback = "\(a.tool) session \(idPart.prefix(8))"
                return SessionCost(
                    id: key,
                    tool: a.tool,
                    cost: a.cost,
                    dominantModel: dominant,
                    messages: a.messages,
                    title: a.title.isEmpty ? fallback : a.title
                )
            }
            .sorted { $0.cost > $1.cost }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Markdown

    static func render(
        sessions: [SessionCost],
        tipsById: [String: [String]],
        insightSource: String,
        lookbackDays: Int,
        totalCost: Double,
        habitTips: [CoachTip],
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append("# Cost Coach — transcript analysis")
        lines.append("")
        lines.append("Generated \(displayFormatter.string(from: now)) from local Claude + Cursor sessions on this Mac.")
        lines.append("Top \(sessions.count) sessions by cost over the last \(lookbackDays) days · **\(Money.string(totalCost))** total.")
        lines.append("")
        lines.append("**Insight engine:** \(insightSource)")
        lines.append("")
        lines.append("> Raw transcripts stay on your Mac. Tips come from local rules over compact stats — no LLM subprocess (avoids macOS Desktop/Music permission sheets). Report path: `~/llm-coach-reports/`.")
        lines.append("")

        lines.append("## Most expensive sessions")
        lines.append("")
        for (idx, s) in sessions.enumerated() {
            let model = s.dominantModel.isEmpty ? "unknown model" : shortModel(s.dominantModel)
            let tips = tipsById[s.id] ?? CoachAdvisor.coachingTips(for: s, limit: 3)
            lines.append("### \(idx + 1). \(s.title)")
            lines.append("")
            lines.append("- **Tool:** \(s.tool) · **Cost:** \(Money.string(s.cost)) · **Turns:** \(s.messages) · **Model:** \(model)")
            lines.append("- **Advice:**")
            for (i, tip) in tips.prefix(3).enumerated() {
                lines.append("  \(i + 1). \(tip)")
            }
            lines.append("")
        }

        if !habitTips.isEmpty {
            lines.append("## Habits that cut cost")
            lines.append("")
            for tip in habitTips {
                lines.append("### \(tip.rank). \(tip.title)")
                lines.append("")
                lines.append(tip.detail)
                lines.append("")
                lines.append("- Don't: \(tip.wrong)")
                lines.append("- Do: \(tip.right)")
                lines.append("")
            }
        }

        lines.append("## Next step")
        lines.append("")
        lines.append("Pick the #1 session above and restart it with the goal, paths, and success check in the first message.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func shortModel(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-thinking", with: "")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.analytics
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.analytics.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
