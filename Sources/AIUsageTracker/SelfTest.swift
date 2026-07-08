import Foundation

// MARK: - Headless self-test
//
// Exercises each unit of functionality separately and prints PASS/FAIL. Run with:
//   AIUsageTracker --self-test
// Pure/nonisolated logic runs synchronously; the @MainActor pipeline runs via a pumped
// run loop (blocking the main thread with a semaphore would deadlock MainActor work).

enum SelfTest {

    private static var passed = 0
    private static var failed = 0

    static func run() -> Int32 {
        print("── AIUsageTracker self-test ──\n")

        testPricingNormalize()
        testPricingCost()
        testClaudeParsingAndDedup()
        testTopSessionsOrdering()
        testCoachingHeuristics()
        testDailySchedule()
        testCursorPersonalAPI()
        testMonthWindow()
        runAsyncPipelineTests()

        print("\n── \(passed) passed, \(failed) failed ──")
        return failed == 0 ? 0 : 1
    }

    // MARK: Assertion helpers

    private static func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        if cond {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            let d = detail()
            print("  ✗ \(name)\(d.isEmpty ? "" : "  — \(d)")")
        }
    }

    private static func approxEqual(_ a: Double, _ b: Double, eps: Double = 0.01) -> Bool {
        abs(a - b) <= eps
    }

    private static func section(_ title: String) { print("\n[\(title)]") }

    // MARK: 1. Pricing — model normalization

    private static func testPricingNormalize() {
        section("TokenPricing.normalize")
        check("opus stays opus", TokenPricing.normalize("claude-opus-4-8") == "claude-opus-4-8")
        check("empty → sonnet default", TokenPricing.normalize("") == TokenPricing.cursorDefaultModel)
        check("\"default\" → sonnet", TokenPricing.normalize("default") == "claude-sonnet-4-6")
        check("composer-* → sonnet", TokenPricing.normalize("composer-2.5") == "claude-sonnet-4-6")
        check("fuzzy haiku match", TokenPricing.normalize("anthropic/claude-haiku-x") == "claude-haiku-4-5")
        check("unknown kept verbatim", TokenPricing.normalize("gpt-5-turbo") == "gpt-5-turbo")
    }

    // MARK: 2. Pricing — cost math (incl. cache + unknown→cheapest)

    private static func testPricingCost() {
        section("TokenPricing.cost")
        let oneM = 1_000_000
        check("haiku input 1M = $1.00",
              approxEqual(TokenPricing.cost(model: "claude-haiku-4-5", usage: TokenUsage(input: oneM)), 1.00))
        check("sonnet output 1M = $15.00",
              approxEqual(TokenPricing.cost(model: "claude-sonnet-4-6", usage: TokenUsage(output: oneM)), 15.00))
        check("opus input 1M = $5.00",
              approxEqual(TokenPricing.cost(model: "claude-opus-4-8", usage: TokenUsage(input: oneM)), 5.00))
        check("opus cache-read 1M = $0.50",
              approxEqual(TokenPricing.cost(model: "claude-opus-4-8", usage: TokenUsage(cacheRead: oneM)), 0.50))
        check("unknown model → cheapest (haiku) $1.00",
              approxEqual(TokenPricing.cost(model: "gpt-5-turbo", usage: TokenUsage(input: oneM)), 1.00))
        check("zero usage = $0.00",
              approxEqual(TokenPricing.cost(model: "claude-opus-4-8", usage: TokenUsage()), 0.0))
    }

    // MARK: 3. Claude parsing + per-message dedup

    private static func testClaudeParsingAndDedup() {
        section("Claude JSONL parsing + dedup")
        guard let dir = makeTempClaudeDir() else {
            check("create temp fixture", false); return
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let byDay = LocalUsageScanner.computeByDay(
            claudeRoot: dir, cursorDB: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        )

        let jul = byDay["2026-07-03"] ?? DayUsageAggregate()
        let jun = byDay["2026-06-30"] ?? DayUsageAggregate()

        // Jul 3: opus in 1M ($5) + sonnet out 1M ($15) + gpt→haiku in 1M ($1) = $21; m1 duped once.
        check("Jul-03 total = $21.00", approxEqual(jul.claudeCost, 21.00), "got \(jul.claudeCost)")
        check("dup message id ignored (S1 = 2 msgs)", jul.sessions["claude:S1"]?.messages == 2,
              "got \(jul.sessions["claude:S1"]?.messages ?? -1)")
        check("S1 cost = $20.00", approxEqual(jul.sessions["claude:S1"]?.cost ?? -1, 20.00))
        check("unknown model priced at cheapest (S3 = $1.00)", approxEqual(jul.sessions["claude:S3"]?.cost ?? -1, 1.00))
        check("day attributed correctly (Jun-30 = $1.00)", approxEqual(jun.claudeCost, 1.00), "got \(jun.claudeCost)")
        check("user/tool lines ignored (Jul-03 msgs = 3)", jul.claudeMessages == 3, "got \(jul.claudeMessages)")
    }

    // MARK: 4. Top-N expensive sessions ordering

    private static func testTopSessionsOrdering() {
        section("Top expensive sessions")
        guard let dir = makeTempClaudeDir() else { check("create temp fixture", false); return }
        defer { try? FileManager.default.removeItem(at: dir) }

        let byDay = LocalUsageScanner.computeByDay(
            claudeRoot: dir, cursorDB: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        )
        let agg = byDay["2026-07-03"] ?? DayUsageAggregate()
        let ranked = agg.sessions.values.filter { $0.cost > 0 }.sorted { $0.cost > $1.cost }
        check("richest session first (S1 $20)", approxEqual(ranked.first?.cost ?? -1, 20.00))
        check("two priced sessions on Jul-03", ranked.count == 2, "got \(ranked.count)")
        check("dominant model resolves (S1 = opus or sonnet tie)",
              ["claude-opus-4-8", "claude-sonnet-4-6"].contains(
                agg.sessions["claude:S1"]?.byModel.max { $0.value < $1.value }?.key ?? ""))
    }

    // MARK: 5. Coaching heuristics

    private static func testCoachingHeuristics() {
        section("CoachAdvisor.coaching")
        let opus = SessionCost(id: "a", tool: "Claude", cost: 20, dominantModel: "claude-opus-4-8", messages: 10, title: "t")
        check("opus-heavy → mentions Sonnet/cheaper",
              CoachAdvisor.coaching(for: opus).lowercased().contains("sonnet"))

        let long = SessionCost(id: "b", tool: "Claude", cost: 5, dominantModel: "claude-sonnet-4-6", messages: 60, title: "t")
        check("long session → mentions turns",
              CoachAdvisor.coaching(for: long).lowercased().contains("turn"))

        let medium = SessionCost(id: "c", tool: "Claude", cost: 5, dominantModel: "claude-sonnet-4-6", messages: 20, title: "t")
        check("medium session → front-load advice",
              CoachAdvisor.coaching(for: medium).lowercased().contains("front-load"))

        let small = SessionCost(id: "d", tool: "Cursor", cost: 1, dominantModel: "claude-sonnet-4-6", messages: 3, title: "t")
        check("small session → non-empty default advice", !CoachAdvisor.coaching(for: small).isEmpty)

        // Daily-rotating tips: stable within a day, different the next day, always 3 ranked 1–3.
        section("CoachAdvisor.tips (daily rotation)")
        let cal = Calendar.analytics
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
        let d1 = CoachAdvisor.tips(on: day(2026, 7, 6))
        let d1noon = CoachAdvisor.tips(on: cal.date(byAdding: .hour, value: 13, to: day(2026, 7, 6))!)
        let d2 = CoachAdvisor.tips(on: day(2026, 7, 7))
        check("returns 3 tips", d1.count == 3, "got \(d1.count)")
        check("ranks are 1,2,3", d1.map(\.rank) == [1, 2, 3])
        check("stable within the same day", d1.map(\.title) == d1noon.map(\.title))
        check("changes the next day", d1.map(\.title) != d2.map(\.title))
        check("no repeats within a day", Set(d1.map(\.title)).count == 3)
    }

    // MARK: 6. Daily schedule math

    private static func testDailySchedule() {
        section("CoachViewModel.nextFireDate")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 8))!
        let sameDay = CoachViewModel.nextFireDate(hour: 9, from: base, calendar: cal)
        check("hour later today → same day 09:00",
              cal.component(.day, from: sameDay) == 5 && cal.component(.hour, from: sameDay) == 9)
        let nextDay = CoachViewModel.nextFireDate(hour: 7, from: base, calendar: cal)
        check("hour already passed → next day 07:00",
              cal.component(.day, from: nextDay) == 6 && cal.component(.hour, from: nextDay) == 7)
    }

    // MARK: 6b. Cursor personal-token API — payload parsing + JWT expiry

    private static func testCursorPersonalAPI() {
        section("CursorPersonalAPI.aggregateDaily")

        // A canned GetFilteredUsageEvents payload: two chargeable events on one day (one with a
        // string-typed token field to exercise coercion) + one non-chargeable event to be excluded.
        let cal = Calendar.analytics
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 12))!
        let ms = Int(day.timeIntervalSince1970 * 1000)
        let dayKey = LocalUsageScanner.dayKey(day)
        let payload: [String: Any] = [
            "totalUsageEventsCount": 3,
            "usageEventsDisplay": [
                ["timestamp": String(ms), "model": "default", "isChargeable": true, "chargedCents": 29.36,
                 "tokenUsage": ["inputTokens": 13389, "outputTokens": 4398, "cacheReadTokens": 1_002_071]],
                ["timestamp": String(ms), "model": "default", "isChargeable": true, "chargedCents": 12.54,
                 "tokenUsage": ["inputTokens": "77265", "outputTokens": 1142, "cacheReadTokens": 87867]], // string coercion
                ["timestamp": String(ms), "model": "default", "isChargeable": false, "chargedCents": 99.0,
                 "tokenUsage": ["inputTokens": 5, "outputTokens": 5, "cacheReadTokens": 5]],               // excluded
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let byDay = CursorPersonalAPI.aggregateDaily(from: data)
        let d = byDay[dayKey] ?? CursorDailyUsage()

        check("non-chargeable event excluded (2 events)", d.events == 2, "got \(d.events)")
        check("cost = (29.36+12.54)¢ = $0.42", approxEqual(d.cost, 0.42), "got \(d.cost)")
        check("input tokens summed incl. string coercion (90654)", d.tokens.input == 90654, "got \(d.tokens.input)")
        check("output tokens summed (5540)", d.tokens.output == 5540, "got \(d.tokens.output)")
        check("cache-read tokens summed (1,089,938)", d.tokens.cacheRead == 1_089_938, "got \(d.tokens.cacheRead)")

        section("JWT.isExpired")
        let past = Date().timeIntervalSince1970 - 3600
        let future = Date().timeIntervalSince1970 + 3600
        check("expired token detected", JWT.isExpired(makeJWT(exp: past)))
        check("valid token not expired", !JWT.isExpired(makeJWT(exp: future)))
        check("non-JWT string → not provably expired", !JWT.isExpired("not.a.jwt-really"))
        check("expiry decodes from valid token", JWT.expiry(makeJWT(exp: future)) != nil)
    }

    /// Builds an unsigned JWT with the given `exp` (seconds) for expiry tests.
    private static func makeJWT(exp: Double) -> String {
        func seg(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(seg("{\"alg\":\"none\"}")).\(seg("{\"exp\":\(Int(exp))}")).sig"
    }

    // MARK: 6c. Month-aware window sizing (the 31st-day drop-off bug)

    private static func testMonthWindow() {
        section("UsageViewModel window (month coverage)")
        let cal = Calendar.analytics
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d))!
        }
        func firstOf(_ date: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: date))! }

        // windowDays: at least historyDays (30), and at least the day-of-month elapsed.
        check("windowDays floors at 30 early in month",
              UsageViewModel.windowDays(today: day(2026, 7, 6)) == 30,
              "got \(UsageViewModel.windowDays(today: day(2026, 7, 6)))")
        check("windowDays = 31 on the 31st",
              UsageViewModel.windowDays(today: day(2026, 7, 31)) == 31,
              "got \(UsageViewModel.windowDays(today: day(2026, 7, 31)))")

        // windowStart must reach day 1 of asOf's month — the bug: on the 31st the old fixed
        // 30-day window started on the 2nd, dropping day 1.
        let cases: [(String, Date)] = [
            ("31-day month, on the 31st", day(2026, 7, 31)),
            ("30-day month, on the 30th", day(2026, 6, 30)),
            ("Feb (non-leap), on the 28th", day(2026, 2, 28)),
            ("Feb (leap), on the 29th", day(2028, 2, 29)),
            ("Dec, on the 31st (year rollover)", day(2026, 12, 31)),
        ]
        for (label, asOf) in cases {
            let start = UsageViewModel.windowStart(asOf: asOf, today: asOf)
            check("covers day 1 — \(label)", start <= firstOf(asOf),
                  "start \(LocalUsageScanner.dayKey(start)) > \(LocalUsageScanner.dayKey(firstOf(asOf)))")
        }

        // Early in the month, the rolling window still reaches ≥30 days back (dashboard context).
        let early = day(2026, 7, 6)
        check("early month keeps 30-day rolling context",
              UsageViewModel.windowStart(asOf: early, today: early) <= day(2026, 6, 7),
              "got \(LocalUsageScanner.dayKey(UsageViewModel.windowStart(asOf: early, today: early)))")
    }

    // MARK: 7. End-to-end pipeline (@MainActor) — data sources + month-to-date + top sessions

    private static func runAsyncPipelineTests() {
        section("End-to-end pipeline (real local data)")
        var done = false

        Task { @MainActor in
            defer { done = true }

            let home = FileManager.default.homeDirectoryForCurrentUser
            let claudeRoot = home.appendingPathComponent(".claude/projects")
            let cursorDB = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

            // 7a. Data source stamps each response with the QUERIED day (the month-to-date bug fix).
            let scanner = LocalUsageScanner(claudeRoot: claudeRoot, cursorDB: cursorDB)
            await scanner.refresh()
            let claude = LocalClaudeDataSource(scanner: scanner)
            let probe = Calendar.analytics.date(from: DateComponents(year: 2026, month: 6, day: 15))!
            let resp = try? await claude.fetchUserCosts(date: probe)
            check("data source asOfDate == queried day",
                  resp?.asOfDate == LocalUsageScanner.dayKey(probe), "got \(resp?.asOfDate ?? "nil")")

            // 7b. Full ViewModel load (uses the shared scanner + real files). Force the LOCAL-file
            // Cursor path so this test stays deterministic — it validates month-to-date *windowing*,
            // not the live personal-token/Admin source (which would pull real server numbers).
            let tokenKey = "cursor.usePersonalToken"
            let prevToken = UserDefaults.standard.object(forKey: tokenKey)
            UserDefaults.standard.set(false, forKey: tokenKey)
            defer {
                if let prevToken { UserDefaults.standard.set(prevToken, forKey: tokenKey) }
                else { UserDefaults.standard.removeObject(forKey: tokenKey) }
            }
            let vm = UsageViewModel()
            await vm.load(force: true)   // bypass throttle so this load definitely runs

            check("load populated a data date", vm.asOfDate != "—")
            check("today ≤ month-to-date", vm.combinedToday <= vm.combinedThisMonth + 0.001)

            // 7c. Month-to-date must equal ONLY the current calendar month (not the 30-day window).
            // Read `expected` from the SAME shared scan vm.load() populated — NOT a fresh
            // computeByDay — so live usage written mid-test can't split the two reads (hermetic).
            if let latest = LocalUsageScanner.parseDay(vm.asOfDate) {
                let cal = Calendar.analytics
                let tc = cal.dateComponents([.year, .month], from: latest)
                var expectedMonth = 0.0
                for k in await LocalUsageScanner.shared.dayKeys() {
                    guard let d = LocalUsageScanner.parseDay(k), d <= latest else { continue }
                    let c = cal.dateComponents([.year, .month], from: d)
                    if c.year == tc.year && c.month == tc.month {
                        let agg = await LocalUsageScanner.shared.aggregate(for: k)
                        expectedMonth += agg.claudeCost + agg.cursorCost
                    }
                }
                check("month-to-date = current-month days only",
                      approxEqual(vm.combinedThisMonth, (expectedMonth * 100).rounded() / 100, eps: 0.05),
                      "vm=\(vm.combinedThisMonth) expected=\(expectedMonth)")
            } else {
                check("parse latest date", false)
            }

            // 7d. Top sessions: at most 3, sorted richest-first, and belong to the reported day.
            check("top sessions ≤ 3", vm.topSessionsToday.count <= 3)
            let costs = vm.topSessionsToday.map { $0.cost }
            check("top sessions sorted desc", costs == costs.sorted(by: >))
            check("top-sessions day == data date", vm.topSessionsDay == vm.asOfDate)
        }

        pumpRunLoop(until: { done }, timeout: 60)
    }

    // MARK: Infrastructure

    /// Writes a deterministic Claude transcript fixture and returns its directory.
    private static func makeTempClaudeDir() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-selftest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return nil }

        func line(_ dict: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: dict)
            return String(data: data, encoding: .utf8)!
        }
        func assistant(_ id: String, _ model: String, day: String, session: String,
                       input: Int = 0, output: Int = 0) -> [String: Any] {
            ["type": "assistant", "timestamp": "\(day)T10:00:00.000Z", "sessionId": session,
             "entrypoint": "cli",
             "message": ["id": id, "model": model,
                         "usage": ["input_tokens": input, "output_tokens": output]]]
        }
        let lines = [
            line(assistant("m1", "claude-opus-4-8", day: "2026-07-03", session: "S1", input: 1_000_000)),
            line(assistant("m1", "claude-opus-4-8", day: "2026-07-03", session: "S1", input: 1_000_000)), // dup id
            line(["type": "user", "message": ["role": "user", "content": "hi"]]),                          // ignored
            line(assistant("m2", "claude-sonnet-4-6", day: "2026-07-03", session: "S1", output: 1_000_000)),
            line(assistant("m4", "gpt-5-turbo", day: "2026-07-03", session: "S3", input: 1_000_000)),      // unknown→cheapest
            line(assistant("m3", "claude-haiku-4-5", day: "2026-06-30", session: "S2", input: 1_000_000)),
        ]
        do {
            try lines.joined(separator: "\n")
                .write(to: dir.appendingPathComponent("fixture.jsonl"), atomically: true, encoding: .utf8)
        } catch { return nil }
        return dir
    }

    /// Pumps the main run loop until `done` or timeout — services @MainActor continuations
    /// without blocking the thread (which would deadlock them).
    private static func pumpRunLoop(until done: () -> Bool, timeout: TimeInterval) {
        let rl = RunLoop.current
        let keepAlive = Timer(timeInterval: 0.01, repeats: true) { _ in }
        rl.add(keepAlive, forMode: .default)
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            rl.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        keepAlive.invalidate()
    }
}
