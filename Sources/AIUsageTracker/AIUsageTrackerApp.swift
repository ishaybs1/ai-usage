import SwiftUI

/// Entry point. The actual UI shell (menu-bar status item, popover, windows) is built in
/// `AppDelegate` using AppKit, because SwiftUI's `MenuBarExtra` doesn't render reliably in a
/// no-Dock app. The `Settings` scene is just a required, invisible placeholder.
struct AIUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@main
enum Main {
    static func main() {
        // Per-functionality self-test: asserts each unit (pricing, parsing, top sessions,
        // coaching, scheduling, and the full @MainActor pipeline) and exits with 0/1.
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }

        // Verify the update feed headlessly. Reads AIUSAGE_UPDATE_URL (or the configured feed).
        if CommandLine.arguments.contains("--update-check") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                defer { sem.signal() }
                print("current version: \(UpdateChecker.currentVersion)")
                print("feed URL: \(UpdateChecker.feedURL?.absoluteString ?? "(none configured)")")
                if let r = await UpdateChecker.check() {
                    print("UPDATE AVAILABLE -> v\(r.version): \(r.message)")
                } else {
                    print("up to date (or no feed / unreachable).")
                }
            }
            sem.wait()
            return
        }

        // Verify the Cursor Admin API against a real key. Reads CURSOR_API_KEY / CURSOR_EMAIL
        // from the environment (or the saved Keychain/prefs) and prints a per-day breakdown.
        if CommandLine.arguments.contains("--cursor-test") {
            let api = CursorAdminAPI()
            let sem = DispatchSemaphore(value: 0)
            // Task.detached (NOT Task {}) so the work runs off the main actor — main() is
            // main-actor-isolated and we block it on sem.wait(), so an inherited-context Task
            // would deadlock (never scheduled).
            Task.detached {
                defer { sem.signal() }
                do {
                    let cfg = CursorConfig.load()
                    guard cfg.isConfigured else {
                        print("Not configured. Set CURSOR_API_KEY and CURSOR_EMAIL (or save them in Settings).")
                        return
                    }
                    let daily = try await api.fetchDaily(days: 30)
                    var lines = ["Cursor usage (last 30 days) for \(cfg.email):"]
                    var total = 0.0
                    for key in daily.keys.sorted() {
                        let d = daily[key]!
                        total += d.cost
                        let models = d.byModel.keys.sorted().joined(separator: ", ")
                        lines.append(String(format: "  %@  $%.2f  %d events  (%@)", key, d.cost, d.events, models))
                    }
                    lines.append(String(format: "TOTAL  $%.2f across %d days", total, daily.count))
                    print(lines.joined(separator: "\n"))
                } catch {
                    print("ERROR: \(error.localizedDescription)")
                }
            }
            sem.wait()
            return
        }

        // Verify the personal-token path (Cursor login on this Mac) against the live endpoint.
        // Reads the session token from Cursor's state.vscdb — no key/config needed.
        if CommandLine.arguments.contains("--cursor-personal-test") {
            let api = CursorPersonalAPI()
            let sem = DispatchSemaphore(value: 0)
            // Task.detached (NOT Task {}) so the work runs on the global pool — main() is
            // main-actor-isolated and we block it on sem.wait() below, so an inherited-context
            // Task would deadlock.
            Task.detached {
                defer { sem.signal() }
                guard await api.isAvailable else {
                    print("No usable Cursor session token found (not signed in, or token expired).")
                    return
                }
                do {
                    let daily = try await api.fetchDaily(days: 7)
                    var lines = ["Cursor usage via personal session token (last 7 days):"]
                    var total = 0.0
                    var tok = TokenUsage()
                    for key in daily.keys.sorted() {
                        let d = daily[key]!
                        total += d.cost
                        tok = tok + d.tokens
                        lines.append(String(format: "  %@  $%.2f  %d events  (in %d / cacheRd %d / out %d)",
                                            key, d.cost, d.events, d.tokens.input, d.tokens.cacheRead, d.tokens.output))
                    }
                    lines.append(String(format: "TOTAL  $%.2f  in %d / cacheRd %d / out %d across %d days",
                                        total, tok.input, tok.cacheRead, tok.output, daily.count))
                    print(lines.joined(separator: "\n"))
                } catch {
                    print("ERROR: \(error.localizedDescription)")
                }
            }
            sem.wait()
            return
        }

        // Export every local session (merged across days) to a CSV file, then exit.
        //   AIUsageTracker --export-sessions [path]
        if let idx = CommandLine.arguments.firstIndex(of: "--export-sessions") {
            let argPath = CommandLine.arguments.indices.contains(idx + 1) ? CommandLine.arguments[idx + 1] : nil
            let path = argPath.map { ($0 as NSString).expandingTildeInPath }
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/ai-usage-sessions.csv")
            SessionExport.run(to: path)
            return
        }

        // Headless self-test: scan local sessions, print a summary, and exit without any UI.
        // Runs the scan synchronously (no actor/Task) to keep the test path simple.
        if CommandLine.arguments.contains("--scan-dump") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let byDay = LocalUsageScanner.computeByDay(
                claudeRoot: home.appendingPathComponent(".claude/projects"),
                cursorDB: home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            )
            var claudeTotal = 0.0, cursorTotal = 0.0
            var lines: [String] = []
            for key in byDay.keys.sorted() {
                let a = byDay[key]!
                claudeTotal += a.claudeCost
                cursorTotal += a.cursorCost
                if a.claudeCost + a.cursorCost > 0 {
                    let models = a.claudeByModel.merging(a.cursorByModel) { $0 + $1 }
                        .keys.sorted().joined(separator: ", ")
                    lines.append(String(format: "%@  Claude $%.2f  Cursor $%.2f  (%@)",
                                        key, a.claudeCost, a.cursorCost, models))
                }
            }
            print("Days with usage: \(lines.count)")
            print(lines.suffix(12).joined(separator: "\n"))
            print(String(format: "TOTAL  Claude $%.2f  Cursor $%.2f  Combined $%.2f",
                         claudeTotal, cursorTotal, claudeTotal + cursorTotal))

            if let latest = byDay.keys.sorted().last, let agg = byDay[latest] {
                let top = agg.sessions.values
                    .filter { $0.cost > 0 }
                    .sorted { $0.cost > $1.cost }
                    .prefix(3)
                print("\nTop 3 sessions on \(latest):")
                for (i, s) in top.enumerated() {
                    let model = s.byModel.max { $0.value < $1.value }?.key ?? "?"
                    print(String(format: "  %d. $%.2f  %@  %@  %d msgs — %@",
                                 i + 1, s.cost, s.tool, model, s.messages, s.title ?? "(untitled)"))
                }
            }
            return
        }
        AIUsageTrackerApp.main()
    }
}
