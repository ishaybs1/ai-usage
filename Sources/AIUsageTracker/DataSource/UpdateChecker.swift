import Foundation

// MARK: - Update check
//
// Lightweight "you're behind" nudge. Fetches a small version feed you host (a raw git file or an
// Artifactory URL) and, if it names a version newer than the running build, surfaces a banner in
// the popover with the update command. Fully optional: if no feed URL is configured it's a no-op
// (no network call, no nudge), so the app works unchanged out of the box.
//
// Enable by either:
//   • editing `defaultFeedURL` below to your hosted feed, or
//   • setting UserDefaults key "update.feedURL", or
//   • exporting AIUSAGE_UPDATE_URL (handy for testing).
//
// The feed is JSON:  {"version": "1.2", "message": "git pull && ./install.sh"}
// (a bare version string like `1.2` also works; message then defaults to the git command).

enum UpdateChecker {
    /// Set this to your hosted feed URL to turn the feature on for everyone. Empty = disabled.
    static let defaultFeedURL = ""

    struct Result: Equatable { let version: String; let message: String }

    static var feedURL: URL? {
        let s = ProcessInfo.processInfo.environment["AIUSAGE_UPDATE_URL"]
            ?? UserDefaults.standard.string(forKey: "update.feedURL")
            ?? defaultFeedURL
        return s.isEmpty ? nil : URL(string: s)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Returns the latest version + update hint IF it's newer than the running build; else nil.
    /// Never throws — any failure (no feed, offline, bad response) yields nil.
    static func check(session: URLSession = .shared) async -> Result? {
        guard let url = feedURL else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return parse(data, current: currentVersion)
    }

    /// Pure parse + compare — split out so the self-test can exercise it with no network.
    static func parse(_ data: Data, current: String) -> Result? {
        var latest = ""
        var message = "git pull && ./install.sh"
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            latest = (obj["version"] as? String) ?? ""
            if let m = obj["message"] as? String, !m.isEmpty { message = m }
        } else if let s = String(data: data, encoding: .utf8) {
            latest = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !latest.isEmpty, isNewer(latest, than: current) else { return nil }
        return Result(version: latest, message: message)
    }

    /// Numeric dotted-version compare, so "1.10" > "1.9" (string compare would get that wrong).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
