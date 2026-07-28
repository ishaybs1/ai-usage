import Foundation

// MARK: - Transcript signals
//
// Lightweight pass over a Claude Code JSONL: repo/branch, model mix, short-prompt rate,
// interrupts, and a few real user lines — enough to write session-specific advice without
// re-sending the whole transcript.

struct TranscriptSignals: Equatable {
    var repo: String?
    var branch: String?
    var aiTitle: String?
    var userPromptCount: Int = 0
    var shortPromptCount: Int = 0      // ≤3 words
    var interruptCount: Int = 0
    var toolUseTurns: Int = 0
    var assistantTurns: Int = 0
    var modelCounts: [String: Int] = [:]
    var samplePrompts: [String] = []   // substantive openers
    var weakPrompts: [String] = []     // short / vague lines

    var shortPromptShare: Double {
        guard userPromptCount > 0 else { return 0 }
        return Double(shortPromptCount) / Double(userPromptCount)
    }

    var opusAssistantShare: Double {
        guard assistantTurns > 0 else { return 0 }
        let opus = modelCounts
            .filter { $0.key.lowercased().contains("opus") }
            .values.reduce(0, +)
        return Double(opus) / Double(assistantTurns)
    }

    var dominantAssistantModel: String? {
        modelCounts.max { $0.value < $1.value }?.key
    }
}

enum TranscriptSignalsLoader {

    /// `sessionKey` is "claude:<uuid>" or "cursor:<id>".
    static func load(sessionKey: String) -> TranscriptSignals? {
        guard sessionKey.hasPrefix("claude:") else { return nil }
        let id = String(sessionKey.dropFirst("claude:".count))
        guard let url = findJSONL(sessionId: id) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data, fileURL: url)
    }

    static func findJSONL(sessionId: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let exact = sessionId + ".jsonl"
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let name = url.lastPathComponent
            if name == exact || name.hasPrefix(sessionId) { return url }
        }
        return nil
    }

    static func parse(data: Data, fileURL: URL) -> TranscriptSignals {
        var s = TranscriptSignals()
        s.repo = ClaudeSessionLabel.repoName(cwd: nil, fileURL: fileURL)

        var lineCount = 0
        for line in utf8Lines(in: data) {
            lineCount += 1
            if lineCount > 12_000 { break }   // cap huge transcripts
            guard let obj = parseJSONObject(line) else { continue }

            if s.branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { s.branch = b }
            if s.repo == nil, let cwd = obj["cwd"] as? String {
                s.repo = ClaudeSessionLabel.repoName(cwd: cwd, fileURL: fileURL)
            }

            let type = obj["type"] as? String
            if type == "ai-title", s.aiTitle == nil,
               let t = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                s.aiTitle = t
            }

            if type == "assistant", let message = obj["message"] as? [String: Any] {
                s.assistantTurns += 1
                if let model = message["model"] as? String, !model.isEmpty {
                    s.modelCounts[model, default: 0] += 1
                }
                if let content = message["content"] as? [[String: Any]],
                   content.contains(where: { ($0["type"] as? String) == "tool_use" }) {
                    s.toolUseTurns += 1
                }
            }

            if type == "user", let text = extractUserText(obj) {
                let lower = text.lowercased()
                if lower.contains("request interrupted") {
                    s.interruptCount += 1
                    continue
                }
                s.userPromptCount += 1
                let words = text.split(whereSeparator: \.isWhitespace)
                if words.count <= 3 {
                    s.shortPromptCount += 1
                    if s.weakPrompts.count < 5 { s.weakPrompts.append(String(text.prefix(80))) }
                } else if s.samplePrompts.count < 8 {
                    s.samplePrompts.append(String(text.prefix(120)))
                }
            }
        }
        return s
    }

    // MARK: Helpers

    private static func extractUserText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        let raw: String?
        if let s = message["content"] as? String {
            raw = s
        } else if let parts = message["content"] as? [[String: Any]] {
            raw = parts.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        } else {
            raw = nil
        }
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("<") { return nil }
        if text.lowercased().hasPrefix("caveat:") { return nil }
        if let nl = text.firstIndex(of: "\n") { text = String(text[..<nl]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func utf8Lines(in data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x0A {
                if start < i { lines.append(data[start..<i]) }
                i = data.index(after: i)
                start = i
            } else {
                i = data.index(after: i)
            }
        }
        if start < data.endIndex { lines.append(data[start..<data.endIndex]) }
        return lines
    }

    private static func parseJSONObject(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
