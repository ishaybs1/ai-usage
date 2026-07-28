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

        // Verify the Cursor Admin API against a real key.
        // from the environment (or saved prefs) and prints a per-day breakdown.
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
                    let days = UsageViewModel.windowDays(today: Date())
                    let daily = try await api.fetchDaily(days: days)
                    var lines = ["Cursor usage via personal session token (last \(days) days, month-to-date window):"]
                    var total = 0.0
                    var tok = TokenUsage()
                    let cal = Calendar.analytics
                    let now = Date()
                    let monthComp = cal.dateComponents([.year, .month], from: now)
                    var mtd = 0.0
                    for key in daily.keys.sorted() {
                        let d = daily[key]!
                        total += d.cost
                        tok = tok + d.tokens
                        if let date = LocalUsageScanner.parseDay(key) {
                            let c = cal.dateComponents([.year, .month], from: date)
                            if c.year == monthComp.year && c.month == monthComp.month { mtd += d.cost }
                        }
                        lines.append(String(format: "  %@  $%.2f  %d events  (in %d / cacheRd %d / out %d)",
                                            key, d.cost, d.events, d.tokens.input, d.tokens.cacheRead, d.tokens.output))
                    }
                    lines.append(String(format: "TOTAL  $%.2f  in %d / cacheRd %d / out %d across %d days",
                                        total, tok.input, tok.cacheRead, tok.output, daily.count))
                    lines.append(String(format: "THIS MONTH (calendar)  $%.2f", mtd))
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
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(
                    "Library/Application Support/AIUsageTracker/ai-usage-sessions.csv"
                )
            SessionExport.run(to: path)
            return
        }

        // Built-in Cost Coach analysis: rank expensive local sessions, write markdown, exit.
        //   AIUsageTracker --analyze
        if CommandLine.arguments.contains("--analyze") {
            let sem = DispatchSemaphore(value: 0)
            var exitCode: Int32 = 0
            Task.detached {
                defer { sem.signal() }
                do {
                    let result = try await TranscriptAnalyzer.run()
                    print("OK — \(result.sessionCount) sessions · \(Money.string(result.totalCost))")
                    print("Insight engine: \(result.insightSource)")
                    print(result.reportURL.path)
                } catch {
                    print("ERROR: \(error.localizedDescription)")
                    exitCode = 1
                }
            }
            sem.wait()
            exit(exitCode)
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
            let cal = Calendar.analytics
            let now = Date()
            let monthComp = cal.dateComponents([.year, .month], from: now)
            var claudeMTD = 0.0
            for key in byDay.keys.sorted() {
                let a = byDay[key]!
                claudeTotal += a.claudeCost
                cursorTotal += a.cursorCost
                if let date = LocalUsageScanner.parseDay(key) {
                    let c = cal.dateComponents([.year, .month], from: date)
                    if c.year == monthComp.year && c.month == monthComp.month { claudeMTD += a.claudeCost }
                }
                if a.claudeCost + a.cursorCost > 0 {
                    let models = a.claudeByModel.merging(a.cursorByModel) { $0 + $1 }
                        .keys.sorted().joined(separator: ", ")
                    lines.append(String(format: "%@  Claude $%.2f  Cursor $%.2f  (%@)",
                                        key, a.claudeCost, a.cursorCost, models))
                }
            }
            print("=== Local scan (list-price estimates) ===")
            print("Days with usage: \(lines.count)")
            print(lines.suffix(12).joined(separator: "\n"))
            print(String(format: "TOTAL  Claude $%.2f  Cursor $%.2f  Combined $%.2f (naive — double-counts Claude Code in Cursor)",
                         claudeTotal, cursorTotal, claudeTotal + cursorTotal))
            print(String(format: "THIS MONTH Claude estimate only  $%.2f", claudeMTD))

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

            // Also fetch Cursor billed costs when a session token is available.
            let api = CursorPersonalAPI()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                defer { sem.signal() }
                guard await api.isAvailable else {
                    print("\n=== Cursor billed (personal token) ===\nNot available — sign into Cursor on this Mac.")
                    return
                }
                do {
                    let days = UsageViewModel.windowDays(today: Date())
                    let daily = try await api.fetchDaily(days: days)
                    var billedTotal = 0.0, billedMTD = 0.0, claudeCLIOnNonCursorDays = 0.0
                    var billedLines: [String] = []
                    for key in daily.keys.sorted() {
                        let d = daily[key]!
                        billedTotal += d.cost
                        if let date = LocalUsageScanner.parseDay(key) {
                            let c = cal.dateComponents([.year, .month], from: date)
                            if c.year == monthComp.year && c.month == monthComp.month { billedMTD += d.cost }
                        }
                        if d.cost > 0 {
                            billedLines.append(String(format: "  %@  $%.2f  %d events", key, d.cost, d.events))
                        }
                    }
                    for key in byDay.keys {
                        guard daily[key]?.cost ?? 0 == 0, let date = LocalUsageScanner.parseDay(key) else { continue }
                        let c = cal.dateComponents([.year, .month], from: date)
                        if c.year == monthComp.year && c.month == monthComp.month {
                            claudeCLIOnNonCursorDays += byDay[key]!.claudeCost
                        }
                    }
                    print("\n=== Cursor billed (personal token — authoritative) ===")
                    print(billedLines.suffix(12).joined(separator: "\n"))
                    print(String(format: "TOTAL billed  $%.2f", billedTotal))
                    print(String(format: "THIS MONTH billed  $%.2f  (+ Claude CLI on non-Cursor days: $%.2f → combined ~$%.2f)",
                                 billedMTD, claudeCLIOnNonCursorDays, billedMTD + claudeCLIOnNonCursorDays))
                } catch {
                    print("\n=== Cursor billed (personal token) ===\nERROR: \(error.localizedDescription)")
                }
            }
            sem.wait()
            return
        }
        AIUsageTrackerApp.main()
    }
}
