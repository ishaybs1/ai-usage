import Foundation
import SQLite3

// MARK: - Local session scanner
//
// Reads Claude Code JSONL transcripts (~/.claude/projects) and Cursor composer bubbles
// (~/Library/Application Support/Cursor/.../state.vscdb), aggregates token usage by day,
// and prices each request at the model that was actually used.

struct DayUsageAggregate: Equatable {
    var claudeCost: Double = 0
    var cursorCost: Double = 0
    var claudeByModel: [String: Double] = [:]
    var cursorByModel: [String: Double] = [:]
    var claudeByProduct: [String: Double] = [:]
    var claudeTokens: TokenUsage = .init()
    var cursorTokens: TokenUsage = .init()
    var claudeSessions: Set<String> = []
    var cursorSessions: Set<String> = []
    var claudeMessages: Int = 0
    var cursorMessages: Int = 0
    /// Per-session spend for THIS day, keyed by "claude:<sessionId>" / "cursor:<composerId>".
    /// Drives the Cost Coach's "3 most expensive sessions today".
    var sessions: [String: SessionAccum] = [:]
}

/// Running per-session totals within a single day.
struct SessionAccum: Equatable {
    var tool: String            // "Claude" / "Cursor"
    var cost: Double = 0
    var messages: Int = 0
    var byModel: [String: Double] = [:]
    var tokens: TokenUsage = .init()
    var title: String?
}

/// One expensive session, surfaced to the Cost Coach.
struct SessionCost: Identifiable, Equatable {
    let id: String
    let tool: String
    let cost: Double
    let dominantModel: String
    let messages: Int
    let title: String
}

actor LocalUsageScanner {

    static let shared = LocalUsageScanner()

    private let claudeRoot: URL
    private let cursorDB: URL
    private let userId = "local_user"
    private let userEmail: String

    private var cache: [String: DayUsageAggregate] = [:]
    private var latestDay: String = ""
    private var earliestDay: String = ""

    init(
        claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        cursorDB: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    ) {
        self.claudeRoot = claudeRoot
        self.cursorDB = cursorDB
        let name = NSFullUserName().isEmpty ? "Me" : NSFullUserName()
        self.userEmail = "\(name.lowercased().replacingOccurrences(of: " ", with: "."))@local"
    }

    var currentUserId: String { userId }

    /// Set via `AIUSAGE_SCAN_TIMING=1` to print per-phase timings to stderr (used by the
    /// headless `--scan-dump` self-test).
    private static let timing = ProcessInfo.processInfo.environment["AIUSAGE_SCAN_TIMING"] == "1"

    func refresh() {
        let byDay = Self.computeByDay(claudeRoot: claudeRoot, cursorDB: cursorDB)
        cache = byDay
        let keys = byDay.keys.sorted()
        earliestDay = keys.first ?? todayKey()
        latestDay = keys.last ?? todayKey()
    }

    /// The full scan, with no actor isolation, so it can run synchronously off any thread
    /// (used by both `refresh()` and the headless self-test — avoids bridging async→sync).
    nonisolated static func computeByDay(claudeRoot: URL, cursorDB: URL) -> [String: DayUsageAggregate] {
        let scanner = LocalUsageScanner(claudeRoot: claudeRoot, cursorDB: cursorDB)
        var byDay: [String: DayUsageAggregate] = [:]
        let t0 = Date()
        scanner.scanClaude(into: &byDay)
        let t1 = Date()
        scanner.scanCursor(into: &byDay)
        let t2 = Date()
        if timing {
            FileHandle.standardError.write(Data(String(
                format: "[timing] claude=%.2fs cursor=%.2fs days=%d\n",
                t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), byDay.count
            ).utf8))
        }
        return byDay
    }

    func dayKeys() -> [String] {
        guard !earliestDay.isEmpty, !latestDay.isEmpty,
              let start = Self.parseDay(earliestDay),
              let end = Self.parseDay(latestDay) else { return [] }
        let cal = Calendar.analytics
        var keys: [String] = []
        var day = start
        while day <= end {
            keys.append(Self.dayKey(day))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }

    func aggregate(for dayKey: String) -> DayUsageAggregate {
        cache[dayKey] ?? DayUsageAggregate()
    }

    /// The `limit` most expensive sessions on `dayKey`, richest first.
    func topSessions(for dayKey: String, limit: Int) -> [SessionCost] {
        let agg = cache[dayKey] ?? DayUsageAggregate()
        return agg.sessions
            .map { key, s -> SessionCost in
                let dominant = s.byModel.max { $0.value < $1.value }?.key ?? ""
                let idPart = key.split(separator: ":").last.map(String.init) ?? key
                let fallback = "\(s.tool) session \(idPart.prefix(8))"
                return SessionCost(id: key, tool: s.tool, cost: s.cost,
                                   dominantModel: dominant, messages: s.messages,
                                   title: s.title ?? fallback)
            }
            .filter { $0.cost > 0 }
            .sorted { $0.cost > $1.cost }
            .prefix(limit)
            .map { $0 }
    }

    func latestAvailableDayKey() -> String {
        latestDay.isEmpty ? todayKey() : latestDay
    }

    // MARK: Claude

    nonisolated private func scanClaude(into byDay: inout [String: DayUsageAggregate]) {
        guard let enumerator = FileManager.default.enumerator(
            at: claudeRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            parseClaudeFile(url, into: &byDay)
        }
    }

    /// Byte marker for a fast pre-filter: only lines containing `"input_tokens"` can carry
    /// usage, so we skip JSON-parsing everything else (most lines) entirely.
    private static let usageMarker = Array("input_tokens".utf8)
    private static let newline: UInt8 = 0x0A

    nonisolated private func parseClaudeFile(_ url: URL, into byDay: inout [String: DayUsageAggregate]) {
        // Read raw bytes and split on '\n'. Iterating a Swift String by grapheme cluster
        // (e.g. split(whereSeparator:)) is pathologically slow on multi-MB files, so we stay
        // at the UTF-8 byte level and only build a String for lines that pass the pre-filter.
        guard let data = try? Data(contentsOf: url) else { return }
        var seenMessageIds = Set<String>()

        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: Self.newline) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            let lineRange = start..<end
            guard lineRange.count > 2 else { continue }
            let lineData = data[lineRange]

            guard Self.contains(lineData, marker: Self.usageMarker),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let msgId = msg["id"] as? String,
                  !seenMessageIds.contains(msgId) else { continue }

            let model = msg["model"] as? String ?? ""
            guard !model.isEmpty, model != "<synthetic>",
                  let usage = msg["usage"] as? [String: Any],
                  (usage["input_tokens"] as? Int ?? 0) > 0
                    || (usage["output_tokens"] as? Int ?? 0) > 0
                    || (usage["cache_read_input_tokens"] as? Int ?? 0) > 0 else { continue }

            seenMessageIds.insert(msgId)

            let tokens = claudeTokens(from: usage)
            let normalized = TokenPricing.normalize(model)
            let cost = TokenPricing.cost(model: normalized, usage: tokens)

            let ts = (obj["timestamp"] as? String).flatMap(Self.parseISO8601) ?? Date()
            let day = Self.dayKey(ts)
            var agg = byDay[day] ?? DayUsageAggregate()
            agg.claudeCost = ((agg.claudeCost + cost) * 100).rounded() / 100
            agg.claudeByModel[normalized, default: 0] = ((agg.claudeByModel[normalized, default: 0] + cost) * 100).rounded() / 100
            let product = claudeProduct(entrypoint: obj["entrypoint"] as? String)
            agg.claudeByProduct[product, default: 0] = ((agg.claudeByProduct[product, default: 0] + cost) * 100).rounded() / 100
            agg.claudeTokens = agg.claudeTokens + tokens
            if let sid = obj["sessionId"] as? String {
                agg.claudeSessions.insert(sid)
                var s = agg.sessions["claude:\(sid)"] ?? SessionAccum(tool: "Claude")
                s.cost = ((s.cost + cost) * 100).rounded() / 100
                s.messages += 1
                s.byModel[normalized, default: 0] += cost
                s.tokens = s.tokens + tokens
                agg.sessions["claude:\(sid)"] = s
            }
            agg.claudeMessages += 1
            byDay[day] = agg
        }
    }

    /// Naive substring search over bytes (Boyer-Moore is overkill for a short marker).
    private static func contains(_ haystack: Data, marker: [UInt8]) -> Bool {
        guard !marker.isEmpty, haystack.count >= marker.count else { return false }
        let first = marker[0]
        return haystack.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            let m = marker.count
            var i = 0
            while i <= n - m {
                if bytes[i] == first {
                    var j = 1
                    while j < m && bytes[i + j] == marker[j] { j += 1 }
                    if j == m { return true }
                }
                i += 1
            }
            return false
        }
    }

    nonisolated private func claudeTokens(from usage: [String: Any]) -> TokenUsage {
        let cache = usage["cache_creation"] as? [String: Any]
        return TokenUsage(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite5m: cache?["ephemeral_5m_input_tokens"] as? Int ?? 0,
            cacheWrite1h: cache?["ephemeral_1h_input_tokens"] as? Int
                ?? usage["cache_creation_input_tokens"] as? Int ?? 0
        )
    }

    nonisolated private func claudeProduct(entrypoint: String?) -> String {
        switch entrypoint {
        case "cli", "claude-vscode": return "claude_code"
        default: return "claude_chat"
        }
    }

    // MARK: Cursor

    nonisolated private func scanCursor(into byDay: inout [String: DayUsageAggregate]) {
        guard FileManager.default.fileExists(atPath: cursorDB.path) else { return }
        var db: OpaquePointer?
        let uri = "file:\(cursorDB.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }

        var composerDates: [String: Date] = [:]
        var composerTitles: [String: String] = [:]
        var composerStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'", -1, &composerStmt, nil) == SQLITE_OK,
              let composerStmt else { return }
        defer { sqlite3_finalize(composerStmt) }

        while sqlite3_step(composerStmt) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(composerStmt, 0),
                  let valC = sqlite3_column_text(composerStmt, 1),
                  let json = String(cString: valC).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
            let key = String(cString: keyC)
            let cid = (obj["composerId"] as? String) ?? key.split(separator: ":").last.map(String.init) ?? ""
            let ms = (obj["lastUpdatedAt"] as? Double) ?? (obj["createdAt"] as? Double)
            if let ms { composerDates[cid] = Date(timeIntervalSince1970: ms / 1000) }
            let raw = ((obj["name"] as? String) ?? (obj["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                composerTitles[cid] = String(raw.split(whereSeparator: \.isNewline).first ?? "").prefix(60).description
            }
        }

        var bubbleStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'", -1, &bubbleStmt, nil) == SQLITE_OK,
              let bubbleStmt else { return }
        defer { sqlite3_finalize(bubbleStmt) }

        while sqlite3_step(bubbleStmt) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(bubbleStmt, 0),
                  let valC = sqlite3_column_text(bubbleStmt, 1),
                  let json = String(cString: valC).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let tc = obj["tokenCount"] as? [String: Any] else { continue }

            let input = tc["inputTokens"] as? Int ?? 0
            let output = tc["outputTokens"] as? Int ?? 0
            guard input + output > 0 else { continue }

            let key = String(cString: keyC)
            let parts = key.split(separator: ":")
            let composerId = parts.count >= 2 ? String(parts[1]) : ""
            let model = cursorModel(from: obj)
            let tokens = TokenUsage(input: input, output: output)
            let normalized = TokenPricing.normalize(model)
            let cost = TokenPricing.cost(model: normalized, usage: tokens)

            let day = Self.dayKey(composerDates[composerId] ?? Date())
            var agg = byDay[day] ?? DayUsageAggregate()
            agg.cursorCost = ((agg.cursorCost + cost) * 100).rounded() / 100
            agg.cursorByModel[normalized, default: 0] = ((agg.cursorByModel[normalized, default: 0] + cost) * 100).rounded() / 100
            agg.cursorTokens = agg.cursorTokens + tokens
            agg.cursorSessions.insert(composerId)
            agg.cursorMessages += 1
            var s = agg.sessions["cursor:\(composerId)"] ?? SessionAccum(tool: "Cursor", title: composerTitles[composerId])
            s.cost = ((s.cost + cost) * 100).rounded() / 100
            s.messages += 1
            s.byModel[normalized, default: 0] += cost
            s.tokens = s.tokens + tokens
            agg.sessions["cursor:\(composerId)"] = s
            byDay[day] = agg
        }
    }

    nonisolated private func cursorModel(from bubble: [String: Any]) -> String {
        if let info = bubble["modelInfo"] as? [String: Any],
           let name = info["modelName"] as? String, !name.isEmpty {
            return name
        }
        return TokenPricing.cursorDefaultModel
    }

    // MARK: Formatting

    private func todayKey() -> String { Self.dayKey(Date()) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current   // local-time day boundaries (matches Calendar.analytics)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func parseDay(_ key: String) -> Date? {
        dayFormatter.date(from: key)
    }

    static func parseISO8601(_ s: String) -> Date? {
        isoParser.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
