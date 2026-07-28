import Foundation
import Security

// MARK: - Cursor Admin API
//
// Recent Cursor usage is no longer stored locally (per-message token counts stopped being
// written to state.vscdb in early 2026). The authoritative source is Cursor's server-side
// Admin API. This client pulls `/teams/filtered-usage-events` — per-event token usage with a
// real `chargedCents` cost, model, and timestamp — filtered to a single user's email, and
// aggregates it by UTC day + model.
//
// Requirements (Cursor's, not ours): a Cursor Team on a plan with the Admin API (Enterprise),
// and a team Admin API key created at cursor.com/dashboard → API Keys. Auth is HTTP Basic with
// the key as the username and an empty password.

/// Configuration for the Cursor Admin API. Key + email live in UserDefaults (same as Slack
/// webhook) — never Keychain, so macOS never shows a password / Keychain access sheet.
/// Environment variables (`CURSOR_API_KEY` / `CURSOR_EMAIL`) override, for CLI tests.
struct CursorConfig {
    var apiKey: String
    var email: String

    var isConfigured: Bool { !apiKey.isEmpty && !email.isEmpty }

    static let apiKeyDefaultsKey = "cursor.adminApiKey"
    static let emailDefaultsKey = "cursor.email"
    /// Legacy Keychain account from older builds — migrated once, then deleted.
    private static let legacyKeychainAccount = "adminApiKey"
    private static let legacyKeychainService = "com.aiusagetracker.cursor"

    static func load() -> CursorConfig {
        let env = ProcessInfo.processInfo.environment
        let key = env["CURSOR_API_KEY"]
            ?? UserDefaults.standard.string(forKey: apiKeyDefaultsKey)
            ?? migrateLegacyKeychainKey()
            ?? ""
        let email = env["CURSOR_EMAIL"]
            ?? UserDefaults.standard.string(forKey: emailDefaultsKey)
            ?? ""
        return CursorConfig(apiKey: key, email: email)
    }

    static func loadEmail() -> String {
        ProcessInfo.processInfo.environment["CURSOR_EMAIL"]
            ?? UserDefaults.standard.string(forKey: emailDefaultsKey)
            ?? ""
    }

    static func save(apiKey: String, email: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: apiKeyDefaultsKey)
        }
        UserDefaults.standard.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: emailDefaultsKey)
        deleteLegacyKeychainItem()
    }

    static var hasStoredApiKey: Bool {
        !(UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "").isEmpty
            || migrateLegacyKeychainKey() != nil
    }

    /// One-shot silent copy from the old Keychain item into UserDefaults (never prompts).
    @discardableResult
    private static func migrateLegacyKeychainKey() -> String? {
        if let existing = UserDefaults.standard.string(forKey: apiKeyDefaultsKey), !existing.isEmpty {
            return nil
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: "FAIL",
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        UserDefaults.standard.set(key, forKey: apiKeyDefaultsKey)
        deleteLegacyKeychainItem()
        return key
    }

    private static func deleteLegacyKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Per-day Cursor usage derived from the API (one entry per UTC day key "yyyy-MM-dd").
struct CursorDailyUsage: Equatable {
    var cost: Double = 0                    // USD, from summed chargedCents
    var byModel: [String: Double] = [:]     // model → USD
    var events: Int = 0                     // chargeable events (proxy for "requests")
    var tokens: TokenUsage = .init()
}

enum CursorAPIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cursor API key/email not set."
        case let .http(code, msg):
            let detail = msg.isEmpty ? "" : " — \(msg)"
            switch code {
            case 401, 403: return "Cursor API rejected the key (HTTP \(code)). Needs a team Admin API key with admin:* scope.\(detail)"
            case 429: return "Cursor API rate limited (HTTP 429). Try again shortly."
            default: return "Cursor API error (HTTP \(code)).\(detail)"
            }
        case let .decode(msg): return "Couldn't read Cursor API response: \(msg)"
        }
    }
}

actor CursorAdminAPI {

    private let endpoint = URL(string: "https://api.cursor.com/teams/filtered-usage-events")!
    private let session: URLSession
    private var config: CursorConfig

    /// Default init loads email only; Admin key is pulled lazily when personal-token needs fallback.
    init(config: CursorConfig? = nil, session: URLSession = .shared) {
        self.config = config ?? CursorConfig(apiKey: "", email: CursorConfig.loadEmail())
        self.session = session
    }

    func updateConfig(_ new: CursorConfig) { config = new }

    var isConfigured: Bool {
        if config.isConfigured { return true }
        let loaded = CursorConfig.load()
        if loaded.isConfigured {
            config = loaded
            return true
        }
        return false
    }

    // MARK: Public

    /// Aggregate this user's Cursor usage for the trailing `days` window, keyed by UTC day.
    func fetchDaily(days: Int) async throws -> [String: CursorDailyUsage] {
        _ = isConfigured   // refresh silent key if present
        guard config.isConfigured else { throw CursorAPIError.notConfigured }
        let cal = Calendar.analytics
        let end = Date()
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: end))!
        let events = try await fetchEvents(start: start, end: end)

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

    /// A quick connectivity/scope check for the settings "Test" button. Returns a short summary.
    func verify() async throws -> String {
        guard config.isConfigured else { throw CursorAPIError.notConfigured }
        let cal = Calendar.analytics
        let end = Date()
        let start = cal.date(byAdding: .day, value: -7, to: end)!
        let events = try await fetchEvents(start: start, end: end, maxPages: 1)
        let total = events.filter(\.isChargeable).reduce(0.0) { $0 + $1.chargedCents } / 100.0
        return "OK — \(events.count) events in the last 7 days for \(config.email) (\(Money.string(total))+ sampled)."
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
        var all: [Event] = []
        var page = 1
        while page <= maxPages {
            let (events, hasNext) = try await fetchPage(start: start, end: end, page: page)
            all.append(contentsOf: events)
            guard hasNext else { break }
            page += 1
        }
        return all
    }

    private func fetchPage(start: Date, end: Date, page: Int) async throws -> (events: [Event], hasNext: Bool) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "startDate": Int(start.timeIntervalSince1970 * 1000),
            "endDate": Int(end.timeIntervalSince1970 * 1000),
            "email": config.email,
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
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorAPIError.decode("not a JSON object")
        }
        let rawEvents = obj["usageEvents"] as? [[String: Any]] ?? []
        let events = rawEvents.compactMap(Self.parseEvent)
        let pagination = obj["pagination"] as? [String: Any]
        let hasNext = (pagination?["hasNextPage"] as? Bool) ?? false
        return (events, hasNext)
    }

    private nonisolated static func parseEvent(_ e: [String: Any]) -> Event? {
        // timestamp is epoch-ms as a string.
        let ms = (e["timestamp"] as? String).flatMap(Double.init)
            ?? (e["timestamp"] as? Double)
        guard let ms else { return nil }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let model = (e["model"] as? String) ?? "unknown"
        let isChargeable = (e["isChargeable"] as? Bool) ?? false
        let charged = (e["chargedCents"] as? Double) ?? 0

        var tokens = TokenUsage()
        if let tu = e["tokenUsage"] as? [String: Any] {
            tokens = TokenUsage(
                input: (tu["inputTokens"] as? Int) ?? 0,
                output: (tu["outputTokens"] as? Int) ?? 0,
                cacheRead: (tu["cacheReadTokens"] as? Int) ?? 0,
                cacheWrite5m: (tu["cacheWriteTokens"] as? Int) ?? 0
            )
        }
        return Event(date: date, model: model, chargedCents: charged,
                     isChargeable: isChargeable, tokens: tokens)
    }

    private func basicAuthHeader() -> String {
        // Basic auth: API key as username, empty password.
        let raw = "\(config.apiKey):"
        let b64 = Data(raw.utf8).base64EncodedString()
        return "Basic \(b64)"
    }
}
