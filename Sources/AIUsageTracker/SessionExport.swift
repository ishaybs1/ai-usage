import Foundation

// MARK: - Session export
//
// Scans all local sessions (Claude JSONL + historical Cursor bubbles), merges each session's
// per-day slices into one row (a session can span multiple days), and writes a CSV sorted by
// cost. NOTE: recent Cursor usage isn't included — Cursor no longer records token/cost data
// locally (see CursorAdminAPI).

enum SessionExport {

    private struct Row {
        var tool: String
        var id: String
        var title: String
        var firstDay: String
        var lastDay: String
        var messages: Int
        var cost: Double
        var byModel: [String: Double]
        var tokens: TokenUsage
    }

    static func run(to path: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let byDay = LocalUsageScanner.computeByDay(
            claudeRoot: home.appendingPathComponent(".claude/projects"),
            cursorDB: home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        )

        // Merge each session's daily slices across all days.
        var rows: [String: Row] = [:]
        for dayKey in byDay.keys.sorted() {
            for (sessionKey, s) in byDay[dayKey]!.sessions {
                let idPart = sessionKey.split(separator: ":").dropFirst().joined(separator: ":")
                var r = rows[sessionKey] ?? Row(
                    tool: s.tool, id: idPart, title: s.title ?? "",
                    firstDay: dayKey, lastDay: dayKey, messages: 0, cost: 0, byModel: [:], tokens: .init()
                )
                r.firstDay = min(r.firstDay, dayKey)
                r.lastDay = max(r.lastDay, dayKey)
                r.messages += s.messages
                r.cost = ((r.cost + s.cost) * 100).rounded() / 100
                for (m, c) in s.byModel { r.byModel[m, default: 0] += c }
                r.tokens = r.tokens + s.tokens
                if r.title.isEmpty, let t = s.title { r.title = t }
                rows[sessionKey] = r
            }
        }

        let sorted = rows.values.sorted { $0.cost > $1.cost }
        var lines = ["tool,session_id,title,first_day,last_day,messages,cost_usd,input_tokens,output_tokens,models"]
        var total = 0.0
        for r in sorted {
            total += r.cost
            let models = r.byModel.keys.sorted().joined(separator: " | ")
            lines.append([
                r.tool, r.id, csv(r.title), r.firstDay, r.lastDay,
                String(r.messages), String(format: "%.2f", r.cost),
                String(r.tokens.input), String(r.tokens.output), csv(models),
            ].joined(separator: ","))
        }

        let csvText = lines.joined(separator: "\n") + "\n"
        do {
            try csvText.write(toFile: path, atomically: true, encoding: .utf8)
            print("Exported \(sorted.count) sessions (\(String(format: "$%.2f", total)) total) to:")
            print("  \(path)")
        } catch {
            FileHandle.standardError.write(Data("Export failed: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Minimal CSV field escaping (quote if it contains a comma/quote/newline).
    private static func csv(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
