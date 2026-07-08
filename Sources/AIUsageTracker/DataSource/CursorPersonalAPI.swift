import Foundation
import SQLite3

// MARK: - Cursor personal-token API
//
// Recent Cursor usage isn't written to disk anymore (per-message token counts stopped in early
// 2026; see CursorAdminAPI / SESSION_HANDOFF). The authoritative source is server-side. This
// client reaches the SAME backend as the Cursor CLI's `/usage` command — the Connect RPC
// `DashboardService/GetFilteredUsageEvents` — but authenticates with the user's OWN session token
// (the one the Cursor app/CLI already stored locally) instead of a Team Admin API key. That
// sidesteps the Enterprise-only Admin-key requirement: if you're signed into Cursor on this Mac,
// this just works.
//
// The token lives in Cursor's global state.vscdb under `cursorAuth/accessToken`. We re-read it on
// every fetch so token refreshes performed by the Cursor app are picked up automatically (no
// refresh flow of our own). The endpoint infers the caller from the token — no team/user id needed.
//
// NOTE: this is a private/undocumented endpoint. It can change without notice; treat failures as
// non-fatal and fall back down the source chain.

/// Reads Cursor's locally-stored session token (read-only) from the global state.vscdb.
enum CursorTokenStore {
    static let defaultDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    /// The access token, or nil if not signed in / DB missing. Never logged — it's a credential.
    static func accessToken(db: URL = defaultDB) -> String? {
        rawValue(forKey: "cursorAuth/accessToken", db: db)
    }

    private static func rawValue(forKey key: String, db: URL) -> String? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        var handle: OpaquePointer?
        let uri = "file:\(db.path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle else { return nil }
        defer { sqlite3_close(handle) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) // SQLITE_TRANSIENT

        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return normalize(String(cString: c))
    }

    /// VS Code's ItemTable stores values as JSON, so a bare string comes back quoted. Strip that.
    private static func normalize(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\""),
           let data = v.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return decoded
        }
        return v
    }
}

/// Decodes the `exp` claim of a JWT to check expiry, without any signature verification (we're only
/// deciding whether it's worth attempting a call — the server is the real authority).
enum JWT {
    /// Seconds-since-epoch expiry, or nil if the token isn't a decodable JWT with an `exp`.
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        // `exp` is seconds; accept Int or Double.
        if let exp = obj["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = obj["exp"] as? Int { return Date(timeIntervalSince1970: Double(exp)) }
        return nil
    }

    /// True when we can prove the token is expired. Unknown/undecodable → false (let the call try).
    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let exp = expiry(token) else { return false }
        return exp <= now
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}

actor CursorPersonalAPI {

    private let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents")!
    private let session: URLSession
    private let dbURL: URL

    init(session: URLSession = .shared, dbURL: URL = CursorTokenStore.defaultDB) {
        self.session = session
        self.dbURL = dbURL
    }

    /// True when a non-expired session token is present on disk (i.e. the user is signed into Cursor).
    var isAvailable: Bool {
        guard let token = CursorTokenStore.accessToken(db: dbURL) else { return false }
        return !JWT.isExpired(token)
    }

    // MARK: Public

    /// Aggregate this user's Cursor usage for the trailing `days` window, keyed by UTC day.
    /// Same shape as `CursorAdminAPI.fetchDaily` so the view model can use either interchangeably.
    func fetchDaily(days: Int) async throws -> [String: CursorDailyUsage] {
        let cal = Calendar.analytics
        let end = Date()
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: end))!
        let events = try await fetchEvents(start: start, end: end)
        return Self.aggregate(events)
    }

    /// Fold events into per-UTC-day totals. Pure; shared by `fetchDaily` and the self-test.
    private nonisolated static func aggregate(_ events: [Event]) -> [String: CursorDailyUsage] {
        var byDay: [String: CursorDailyUsage] = [:]
        for e in events {
            guard e.isChargeable else { continue }
            let day = LocalUsageScanner.dayKey(e.date)
            var d = byDay[day] ?? CursorDailyUsage()
            let usd = e.chargedCents / 100.0
            d.cost = ((d.cost + usd) * 100).rounded() / 100
            let model = Labels.cursorModel(e.model)
            d.byModel[model, default: 0] = ((d.byModel[model, default: 0] + usd) * 100).rounded() / 100
            d.events += 1
            d.tokens = d.tokens + e.tokens
            byDay[day] = d
        }
        return byDay
    }

    /// Test-facing entry point: raw response payload → per-day aggregate, no network.
    nonisolated static func aggregateDaily(from data: Data) -> [String: CursorDailyUsage] {
        aggregate(parseResponse(data).events)
    }

    /// Connectivity check for the Settings "Test" button. Returns a short human summary.
    func verify() async throws -> String {
        guard CursorTokenStore.accessToken(db: dbURL) != nil else { throw CursorAPIError.notConfigured }
        let cal = Calendar.analytics
        let end = Date()
        let start = cal.date(byAdding: .day, value: -7, to: end)!
        let events = try await fetchEvents(start: start, end: end, maxPages: 1)
        let total = events.filter(\.isChargeable).reduce(0.0) { $0 + $1.chargedCents } / 100.0
        return "OK — \(events.count) events in the last 7 days via your Cursor session (\(Money.string(total))+ sampled)."
    }

    // MARK: Networking

    private struct Event {
        let date: Date
        let model: String
        let chargedCents: Double
        let isChargeable: Bool
        let tokens: TokenUsage
    }

    private func fetchEvents(start: Date, end: Date, maxPages: Int = 200) async throws -> [Event] {
        guard let token = CursorTokenStore.accessToken(db: dbURL) else { throw CursorAPIError.notConfigured }
        var all: [Event] = []
        var page = 1
        while page <= maxPages {
            let (events, total) = try await fetchPage(token: token, start: start, end: end, page: page)
            all.append(contentsOf: events)
            // Stop when we've collected everything the server reports, or a page came back empty.
            if events.isEmpty || all.count >= total { break }
            page += 1
        }
        return all
    }

    private func fetchPage(token: String, start: Date, end: Date, page: Int) async throws -> (events: [Event], total: Int) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // int64 proto fields (start/end) are JSON-encoded as strings. The endpoint infers the
        // caller (team/user) from the token, so we send only the window + paging.
        let body: [String: Any] = [
            "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(end.timeIntervalSince1970 * 1000)),
            "page": page,
            "pageSize": 1000,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CursorAPIError.http(-1, "no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw CursorAPIError.http(http.statusCode, msg)
        }
        return Self.parseResponse(data)
    }

    /// Parse a GetFilteredUsageEvents response into events + the server's total count.
    private nonisolated static func parseResponse(_ data: Data) -> (events: [Event], total: Int) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], 0)
        }
        let raw = obj["usageEventsDisplay"] as? [[String: Any]] ?? []
        let total = (obj["totalUsageEventsCount"] as? Int)
            ?? Int((obj["totalUsageEventsCount"] as? String) ?? "") ?? raw.count
        return (raw.compactMap(parseEvent), total)
    }

    private nonisolated static func parseEvent(_ e: [String: Any]) -> Event? {
        let ms = (e["timestamp"] as? String).flatMap(Double.init) ?? (e["timestamp"] as? Double)
        guard let ms else { return nil }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let model = (e["model"] as? String) ?? "unknown"
        let isChargeable = (e["isChargeable"] as? Bool) ?? false
        let charged = (e["chargedCents"] as? Double) ?? Double((e["chargedCents"] as? String) ?? "") ?? 0

        var tokens = TokenUsage()
        if let tu = e["tokenUsage"] as? [String: Any] {
            tokens = TokenUsage(
                input: intField(tu["inputTokens"]),
                output: intField(tu["outputTokens"]),
                cacheRead: intField(tu["cacheReadTokens"]),
                cacheWrite5m: intField(tu["cacheWriteTokens"])
            )
        }
        return Event(date: date, model: model, chargedCents: charged,
                     isChargeable: isChargeable, tokens: tokens)
    }

    /// Token counts can arrive as Int, Double, or numeric String across payloads — coerce safely.
    private nonisolated static func intField(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }
}
