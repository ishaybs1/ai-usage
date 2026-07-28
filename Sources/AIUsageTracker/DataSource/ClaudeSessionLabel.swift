import Foundation

// MARK: - Human-readable Claude session labels
//
// Replaces "Claude session cdaf8825" with something a person can recognize:
//   artifactory-federation — Continue XFF E2E scalability testing
// Prefer Claude's own `aiTitle` + `cwd` repo; fall back to the first real user prompt
// trimmed to ~5 words, then to the project folder name encoded in the JSONL path.

enum ClaudeSessionLabel {

    /// Build "repo — summary" from one session JSONL (already loaded).
    static func make(from data: Data, fileURL: URL) -> String? {
        var cwd: String?
        var aiTitle: String?
        var firstUser: String?

        var lineCount = 0
        for line in utf8Lines(in: data) {
            lineCount += 1
            guard let obj = parseJSONObject(line) else { continue }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }

            let type = obj["type"] as? String
            if aiTitle == nil, type == "ai-title",
               let t = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                aiTitle = t
            }
            if firstUser == nil, type == "user", let text = userText(from: obj) {
                firstUser = text
            }
            // Prefer aiTitle when present; stop early once we have repo + title.
            if cwd != nil && aiTitle != nil { break }
            // Give aiTitle a chance to appear before settling on a user-prompt fallback.
            if lineCount >= 400 && cwd != nil && (aiTitle != nil || firstUser != nil) { break }
            if lineCount >= 800 { break }
        }

        let repo = repoName(cwd: cwd, fileURL: fileURL)
        let summary = summarize(aiTitle: aiTitle, firstUser: firstUser)
        switch (repo, summary) {
        case let (r?, s?): return "\(r) — \(s)"
        case let (r?, nil): return r
        case let (nil, s?): return s
        case (nil, nil): return nil
        }
    }

    // MARK: Pieces

    static func repoName(cwd: String?, fileURL: URL) -> String? {
        if let cwd, let name = lastPathComponent(cwd), !isBoringRepo(name) {
            return name
        }
        // Parent folder is often "-Users-…-Desktop-projects-artifactory-federation"
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        if parent == "subagents" {
            return repoName(cwd: nil, fileURL: fileURL.deletingLastPathComponent())
        }
        return decodeProjectDir(parent)
    }

    /// Prefer Claude's aiTitle; else ~5 words from the first real user prompt.
    static func summarize(aiTitle: String?, firstUser: String?) -> String? {
        if let t = aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return truncateWords(clean(t), maxWords: 8)
        }
        if let u = firstUser {
            let cleaned = clean(u)
            guard !cleaned.isEmpty else { return nil }
            return truncateWords(cleaned, maxWords: 5)
        }
        return nil
    }

    // MARK: Helpers

    private static func userText(from obj: [String: Any]) -> String? {
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
        // Skip slash-commands / tool wrappers / meta noise.
        if text.hasPrefix("<") { return nil }
        if text.lowercased().hasPrefix("caveat:") { return nil }
        if text.hasPrefix("/") { return nil }
        // First line only.
        if let nl = text.firstIndex(of: "\n") {
            text = String(text[..<nl])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func truncateWords(_ s: String, maxWords: Int) -> String {
        let words = s.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWords else { return s }
        return words.prefix(maxWords).joined(separator: " ")
    }

    private static func lastPathComponent(_ path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func isBoringRepo(_ name: String) -> Bool {
        name == "/" || name == "projects" || name == "Desktop" || name == "Users" || name.hasPrefix(".")
    }

    /// "-Users-ishaybs-Desktop-projects-artifactory-federation" → "artifactory-federation"
    static func decodeProjectDir(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        let parts = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        // Drop leading empty from the initial "-".
        let tokens = parts.dropFirst().filter { !$0.isEmpty }
        guard let idx = tokens.lastIndex(of: "projects"), idx + 1 < tokens.count else {
            return tokens.last
        }
        let repo = tokens[(idx + 1)...].joined(separator: "-")
        return repo.isEmpty ? tokens.last : repo
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
