import Foundation

// MARK: - UsageViewModel
//
// Consumes an `AnalyticsDataSource` (Claude) AND a `CursorDataSource` (Cursor) and derives
// everything the UI needs, combining the two providers into "all AI tools":
//   • personal: my spend today / month (per tool + combined), my Claude breakdowns
//   • org/dashboard: per-user ranking (Claude / Cursor / total), per-tool time series, KPIs
//
// It depends ONLY on the protocols, so swapping mock → live is the two `init` defaults below.

@MainActor
final class UsageViewModel: ObservableObject {

    /// Date ranges offered by the dashboard selector.
    enum DateRange: String, CaseIterable, Identifiable {
        case today = "Today"
        case last7 = "7 Days"
        case thisMonth = "This Month"
        var id: String { rawValue }
    }

    /// One model row for the personal dashboard breakdown.
    struct ModelSpend: Identifiable, Equatable {
        let model: String
        let claudeCost: Double
        let cursorCost: Double
        var total: Double { ((claudeCost + cursorCost) * 100).rounded() / 100 }
        var id: String { model }
    }

    /// One ranking row: a user's spend over the selected range, split by tool.
    struct UserSpend: Identifiable, Equatable {
        let id: String      // userId
        let email: String
        let claudeCost: Double
        let cursorCost: Double
        let commits: Int
        let linesOfCode: Int
        var total: Double { ((claudeCost + cursorCost) * 100).rounded() / 100 }
        /// ROI: combined spend per commit over the range, or nil when there were no commits.
        var costPerCommit: Double? {
            commits > 0 ? (total / Double(commits) * 100).rounded() / 100 : nil
        }
        /// Best-effort display name derived from the email local-part (API returns no name).
        var displayName: String {
            let local = email.split(separator: "@").first.map(String.init) ?? email
            return local.split(separator: ".").map { $0.capitalized }.joined(separator: " ")
        }
    }

    /// One per-tool point in the spend-over-time series (drives the stacked bar chart).
    struct ToolDailyPoint: Identifiable, Equatable {
        let id: String      // "yyyy-MM-dd|tool"
        let date: Date
        let tool: String    // "Claude" / "Cursor"
        let amount: Double
    }

    /// Budget tracking state for the menu-bar color + popover warning.
    enum BudgetStatus {
        case none      // no budget set
        case under     // on track, within budget
        case warning   // projected to exceed by month end
        case over      // month-to-date already exceeds the cap
    }

    /// Where RECENT Cursor usage came from on the last load. Precedence: personalToken → adminAPI
    /// → localFiles. Surfaced in Settings so the user always knows which source is live.
    enum CursorSource: Equatable {
        case personalToken   // your Cursor session token (from the app/CLI login) — the default
        case adminAPI        // a Team Admin API key (Enterprise)
        case localFiles      // on-disk scan (no recent token data since mid-2026)

        var label: String {
            switch self {
            case .personalToken: return "Personal session token (Cursor login on this Mac)"
            case .adminAPI: return "Team Admin API key"
            case .localFiles: return "Local files (no recent Cursor data)"
            }
        }
    }

    // MARK: Inputs

    private let dataSource: AnalyticsDataSource
    private let cursorSource: CursorDataSource
    private let activitySource: ActivityDataSource
    /// Server-side sources for RECENT Cursor usage (local files no longer carry token counts).
    /// `cursorPersonalAPI` uses your local Cursor session token; `cursorAPI` uses a Team Admin key.
    private let cursorPersonalAPI = CursorPersonalAPI()
    private let cursorAPI = CursorAdminAPI()

    /// SINGLE SWITCH POINT: defaults read local Claude + Cursor session files on this Mac.
    init(dataSource: AnalyticsDataSource = LocalClaudeDataSource(),
         cursorSource: CursorDataSource = LocalCursorDataSource(),
         activitySource: ActivityDataSource = LocalActivityDataSource()) {
        self.dataSource = dataSource
        self.cursorSource = cursorSource
        self.activitySource = activitySource
        self.monthlyBudget = UserDefaults.standard.double(forKey: Self.budgetKey)
        self.manualCursorMonth = UserDefaults.standard.double(forKey: Self.manualCursorKey)
        // Default ON: if the user is signed into Cursor, use their session token automatically.
        self.usePersonalToken = UserDefaults.standard.object(forKey: Self.usePersonalTokenKey) as? Bool ?? true
        // Eagerly load at startup so the menu-bar title is populated before the popover opens.
        Task { await load() }
    }

    /// The signed-in user's id, for highlighting "you" in the ranking table.
    var currentUserId: String { dataSource.currentUserId }

    /// The menu-bar title shows COMBINED (all-tools) spend today.
    var menuBarTitle: String {
        asOfDate == "—" ? "$…" : Money.string(combinedToday)
    }

    // MARK: Published state

    /// The authoritative data date (from the API's `as_of_date`) — surfaced as "Data as of …".
    @Published private(set) var asOfDate: String = "—"
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    // Personal (menu-bar popover)
    @Published private(set) var mySpendToday: Double = 0          // Claude
    @Published private(set) var mySpendThisMonth: Double = 0      // Claude
    @Published private(set) var myCursorToday: Double = 0
    @Published private(set) var myCursorThisMonth: Double = 0
    @Published private(set) var myCursorFastToday: Int = 0
    @Published private(set) var myCursorTotalRequestsToday: Int = 0
    @Published private(set) var myProductBreakdown: [String: Double] = [:]
    @Published private(set) var myModelBreakdown: [String: Double] = [:]
    @Published private(set) var myCursorModelBreakdown: [String: Double] = [:]
    /// The day the top-sessions list is for ("yyyy-MM-dd"), and the 3 priciest sessions on it.
    @Published private(set) var topSessionsDay: String = "—"
    @Published private(set) var topSessionsToday: [SessionCost] = []

    /// Cursor data source state, for the popover/settings: whether a server source is in use and any error.
    @Published private(set) var cursorUsingAPI = false
    @Published private(set) var cursorApiStatus: String? = nil   // nil = OK / not configured
    /// Which source produced recent Cursor usage on the last load (for the Settings indicator).
    @Published private(set) var cursorSourceInUse: CursorSource = .localFiles
    /// True when we have NO recent Cursor data (no server source usable) — local files no longer
    /// carry it, so we show "unavailable" rather than misleading stale numbers.
    @Published private(set) var cursorRecentUnavailable = false

    /// Auto-use the local Cursor session token (default on). Turning it off falls back down the
    /// chain (Admin API → local/manual) — an escape hatch for the private-endpoint dependency.
    @Published var usePersonalToken: Bool {
        didSet {
            UserDefaults.standard.set(usePersonalToken, forKey: Self.usePersonalTokenKey)
            Task { await load() }
        }
    }

    /// Manual month-to-date Cursor spend (USD) the user can read off cursor.com and type in, used
    /// only when the API isn't providing data. 0 = unset.
    @Published var manualCursorMonth: Double {
        didSet {
            UserDefaults.standard.set(manualCursorMonth, forKey: Self.manualCursorKey)
            recomputePersonal()
        }
    }

    private var cursorEmail: String { CursorConfig.loadEmail() }
    /// Whether the month-to-date Cursor figure currently comes from the manual override.
    var cursorMonthIsManual: Bool { cursorRecentUnavailable && manualCursorMonth > 0 }

    /// Re-read Cursor config (after the user saves it in Settings) and reload.
    func applyCursorConfig(_ cfg: CursorConfig) async {
        await cursorAPI.updateConfig(cfg)
        await load(force: true)   // config changed — bypass the throttle
    }
    /// Combined model spend for the selected dashboard range (Claude + Cursor).
    @Published private(set) var modelBreakdown: [ModelSpend] = []

    // Personal ROI (output produced for the spend).
    @Published private(set) var myCommitsToday: Int = 0
    @Published private(set) var myCommitsThisMonth: Int = 0

    /// Combined (all-tools) personal spend per commit this month, or nil with no commits.
    var myCostPerCommit: Double? {
        myCommitsThisMonth > 0 ? (combinedThisMonth / Double(myCommitsThisMonth) * 100).rounded() / 100 : nil
    }

    /// Combined (all-tools) personal spend on the previous available day — for the ▲▼ delta.
    @Published private(set) var combinedYesterday: Double = 0

    var combinedToday: Double { ((mySpendToday + myCursorToday) * 100).rounded() / 100 }
    var combinedThisMonth: Double { ((mySpendThisMonth + myCursorThisMonth) * 100).rounded() / 100 }

    /// Fractional change today vs the previous day (e.g. 0.12 = +12%); nil if no baseline.
    var dayOverDayDelta: Double? {
        guard combinedYesterday > 0 else { return nil }
        return (combinedToday - combinedYesterday) / combinedYesterday
    }

    // MARK: Budget

    /// User's monthly cap (0 = unset). Persisted; drives the menu-bar color + popover warning.
    @Published var monthlyBudget: Double {
        didSet { UserDefaults.standard.set(monthlyBudget, forKey: Self.budgetKey) }
    }

    /// Linear projection of personal month spend from month-to-date.
    var projectedMonthSpend: Double {
        guard let asOf = Self.parse(asOfDate) else { return combinedThisMonth }
        let cal = Calendar.analytics
        let elapsed = cal.component(.day, from: asOf)
        let total = cal.range(of: .day, in: .month, for: asOf)?.count ?? elapsed
        guard elapsed > 0 else { return combinedThisMonth }
        return (combinedThisMonth / Double(elapsed) * Double(total) * 100).rounded() / 100
    }

    var budgetStatus: BudgetStatus {
        guard monthlyBudget > 0 else { return .none }
        if combinedThisMonth >= monthlyBudget { return .over }
        if projectedMonthSpend > monthlyBudget { return .warning }
        return .under
    }

    /// Human-readable warning for the popover, or nil when within budget / unset.
    var budgetWarning: String? {
        switch budgetStatus {
        case .over:
            return "Over budget — \(Money.string(combinedThisMonth)) of \(Money.string(monthlyBudget)) this month."
        case .warning:
            return "Trending over — projected \(Money.string(projectedMonthSpend)) vs \(Money.string(monthlyBudget)) cap."
        case .under, .none:
            return nil
        }
    }

    // Dashboard
    @Published var selectedRange: DateRange = .today {
        didSet { recomputeDashboard() }
    }
    @Published private(set) var ranking: [UserSpend] = []
    @Published private(set) var toolSeries: [ToolDailyPoint] = []
    @Published private(set) var totalSpend: Double = 0       // combined
    @Published private(set) var claudeTotal: Double = 0
    @Published private(set) var cursorTotal: Double = 0
    @Published private(set) var activeUsers: Int = 0
    @Published private(set) var averagePerUser: Double = 0
    // Dashboard ROI (output for the spend, over the selected range).
    @Published private(set) var totalCommits: Int = 0
    @Published private(set) var totalLinesOfCode: Int = 0
    @Published private(set) var totalConversations: Int = 0
    @Published private(set) var totalMessages: Int = 0
    /// Org-wide combined spend per commit, or nil when there were no commits in the range.
    var costPerCommit: Double? {
        totalCommits > 0 ? (totalSpend / Double(totalCommits) * 100).rounded() / 100 : nil
    }

    // MARK: Internal cache

    /// Claude history, ordered oldest → newest.
    private var history: [UserCostResponse] = []
    /// Cursor cost indexed by day → userId → USD (aligned to the same dates).
    private var cursorCostIndex: [String: [String: Double]] = [:]
    /// Per-model spend indexed by day (from local session scan).
    private var claudeModelIndex: [String: [String: Double]] = [:]
    private var cursorModelIndex: [String: [String: Double]] = [:]
    /// Latest-day Cursor usage per user (for personal request counts).
    private var cursorTodayByUser: [String: CursorUsage] = [:]
    /// Activity indexed by day → userId → activity (aligned to the same dates).
    private var activityIndex: [String: [String: UserActivity]] = [:]

    // MARK: Loading

    /// Fetch the latest available day, then the trailing history window for BOTH providers,
    /// and compute everything.
    func load(force: Bool = false) async {
        // Throttle: opening several windows in quick succession (each triggers load) would
        // otherwise fire redundant fetches and show slightly different live numbers across windows.
        // Reuse the last result within `loadThrottle`; the timer / Refresh button pass force:true.
        if !force, let last = lastLoadedAt, Date().timeIntervalSince(last) < Self.loadThrottle { return }
        lastLoadedAt = Date()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            await LocalUsageScanner.shared.refresh()
            let localKeys = await LocalUsageScanner.shared.dayKeys()
            let localLatest = await LocalUsageScanner.shared.latestAvailableDayKey()

            // Recent Cursor usage isn't stored on disk anymore, so pull it from a server source by
            // precedence: (1) your local Cursor session token, (2) a Team Admin API key, (3) give
            // up → local/manual. Each source self-heals to the next on failure. Non-fatal — Claude
            // (local) keeps working regardless.
            var apiDaily: [String: CursorDailyUsage] = [:]
            var resolvedSource: CursorSource = .localFiles
            var sourceError: String? = nil

            // Window must always cover the FULL current calendar month, not a fixed 30 days —
            // otherwise day 1 drops off on the 31st of a 31-day month (see responsesInMonth).
            let windowDays = Self.windowDays(today: Date())

            if usePersonalToken, await cursorPersonalAPI.isAvailable {
                do {
                    apiDaily = try await cursorPersonalAPI.fetchDaily(days: windowDays)
                    resolvedSource = .personalToken
                } catch {
                    sourceError = error.localizedDescription
                }
            }
            if resolvedSource == .localFiles, await cursorAPI.isConfigured {
                do {
                    apiDaily = try await cursorAPI.fetchDaily(days: windowDays)
                    resolvedSource = .adminAPI
                    sourceError = nil
                } catch {
                    sourceError = error.localizedDescription
                }
            }

            let usingAPI = resolvedSource != .localFiles
            cursorSourceInUse = resolvedSource
            cursorUsingAPI = usingAPI
            cursorApiStatus = usingAPI ? nil : sourceError
            // Recent Cursor is "unavailable" whenever no server source produced data — local files
            // stopped carrying recent Cursor usage in mid-2026.
            cursorRecentUnavailable = !usingAPI

            // Latest day is the newest of local sessions (Claude) and the API (recent Cursor),
            // so a Cursor-only day like "today" still shows up.
            let apiLatest = apiDaily.keys.max() ?? ""
            let latestKey = [localLatest, apiLatest].filter { !$0.isEmpty }.max()
                ?? LocalUsageScanner.dayKey(Date())

            guard !localKeys.isEmpty || !apiDaily.isEmpty else {
                asOfDate = LocalUsageScanner.dayKey(Date())
                history = []
                cursorCostIndex = [:]
                claudeModelIndex = [:]
                cursorModelIndex = [:]
                topSessionsDay = asOfDate
                topSessionsToday = []
                recomputePersonal()
                recomputeDashboard()
                return
            }

            asOfDate = latestKey
            guard let asOf = Self.parse(latestKey) else {
                errorMessage = "Could not parse data date \"\(latestKey)\"."
                return
            }

            let cal = Calendar.analytics
            let start = Self.windowStart(asOf: asOf, today: Date())

            var responses: [UserCostResponse] = []
            var cursorHistory: [CursorUsageResponse] = []
            var activityHistory: [UserActivityResponse] = []
            var claudeModels: [String: [String: Double]] = [:]
            var cursorModels: [String: [String: Double]] = [:]

            // Walk a CONTIGUOUS day window so API days with no local session still appear.
            var day = start
            while day <= asOf {
                let key = LocalUsageScanner.dayKey(day)
                let agg = await LocalUsageScanner.shared.aggregate(for: key)
                claudeModels[key] = agg.claudeByModel

                responses.append(try await dataSource.fetchUserCosts(date: day))
                activityHistory.append(try await activitySource.fetchUserActivity(date: day))

                if usingAPI {
                    let d = apiDaily[key] ?? CursorDailyUsage()
                    cursorModels[key] = d.byModel
                    let u = CursorUsage(userId: currentUserId, email: cursorEmail,
                                        costUsd: d.cost, fastRequests: d.events, totalRequests: d.events)
                    cursorHistory.append(CursorUsageResponse(data: [u], asOfDate: key,
                                                             hasMore: false, nextCursor: nil))
                } else {
                    cursorModels[key] = agg.cursorByModel
                    cursorHistory.append(try await cursorSource.fetchCursorUsage(date: day))
                }

                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }

            history = responses
            claudeModelIndex = claudeModels
            cursorModelIndex = cursorModels
            indexCursor(cursorHistory)
            indexActivity(activityHistory)

            // The Cost Coach targets the 3 most expensive sessions of the latest day; this
            // recomputes on every load (incl. the 15-min timer), so it rolls over daily.
            topSessionsDay = latestKey
            topSessionsToday = await LocalUsageScanner.shared.topSessions(for: latestKey, limit: 3)

            recomputePersonal()
            recomputeDashboard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func indexCursor(_ responses: [CursorUsageResponse]) {
        var index: [String: [String: Double]] = [:]
        for resp in responses {
            index[resp.asOfDate] = Dictionary(uniqueKeysWithValues: resp.data.map { ($0.userId, $0.costUsd) })
        }
        cursorCostIndex = index
        if let lastDay = responses.last {
            cursorTodayByUser = Dictionary(uniqueKeysWithValues: lastDay.data.map { ($0.userId, $0) })
        }
    }

    private func indexActivity(_ responses: [UserActivityResponse]) {
        var index: [String: [String: UserActivity]] = [:]
        for resp in responses {
            index[resp.asOfDate] = Dictionary(uniqueKeysWithValues: resp.data.map { ($0.userId, $0) })
        }
        activityIndex = index
    }

    // MARK: Personal computations

    /// Local Claude JSONL cost for one user/day. When Cursor's billing API is active, days with
    /// Cursor billed spend are excluded — those sessions are already in the API total (Claude Code).
    private func claudeCostUsd(on dayKey: String, userId: String, response: UserCostResponse) -> Double {
        if cursorUsingAPI, (cursorCostIndex[dayKey]?[userId] ?? 0) > 0 { return 0 }
        return response.data.first { $0.userId == userId }?.costUsd ?? 0
    }

    private func recomputePersonal() {
        guard let today = history.last else { return }
        let me = dataSource.currentUserId

        // Today's Claude spend + breakdowns.
        let mine = today.data.first { $0.userId == me }
        mySpendToday = claudeCostUsd(on: today.asOfDate, userId: me, response: today)
        let cursorCoversToday = cursorUsingAPI && (cursorCostIndex[today.asOfDate]?[me] ?? 0) > 0
        myProductBreakdown = cursorCoversToday ? [:] : (mine?.breakdown?.byProduct ?? [:])
        myModelBreakdown = cursorCoversToday ? [:] : (mine?.breakdown?.byModel ?? [:])
        myCursorModelBreakdown = cursorModelIndex[today.asOfDate] ?? [:]

        // Today's Cursor spend + fast requests.
        myCursorToday = cursorCostIndex[today.asOfDate]?[me] ?? 0
        myCursorFastToday = cursorTodayByUser[me]?.fastRequests ?? 0
        myCursorTotalRequestsToday = cursorTodayByUser[me]?.totalRequests ?? 0

        // Month-to-date (both tools): same calendar month as as_of, up to and including it.
        guard let asOf = Self.parse(today.asOfDate) else {
            mySpendThisMonth = mySpendToday; myCursorThisMonth = myCursorToday; return
        }
        let monthResponses = responsesInMonth(of: asOf)
        mySpendThisMonth = monthResponses.reduce(0) {
            $0 + claudeCostUsd(on: $1.asOfDate, userId: me, response: $1)
        }
        myCursorThisMonth = monthResponses.reduce(0) { $0 + (cursorCostIndex[$1.asOfDate]?[me] ?? 0) }
        // Fallback: with no recent Cursor data, use the user's manually-entered month spend so the
        // combined total stays real (rather than silently dropping Cursor).
        if cursorMonthIsManual { myCursorThisMonth = manualCursorMonth }

        // ROI: my commits today and month-to-date.
        myCommitsToday = activityIndex[today.asOfDate]?[me]?.commits ?? 0
        myCommitsThisMonth = monthResponses.reduce(0) { $0 + (activityIndex[$1.asOfDate]?[me]?.commits ?? 0) }

        // Previous available day (for the ▲▼ delta).
        if history.count >= 2 {
            let prev = history[history.count - 2]
            let claudeY = claudeCostUsd(on: prev.asOfDate, userId: me, response: prev)
            let cursorY = cursorCostIndex[prev.asOfDate]?[me] ?? 0
            combinedYesterday = ((claudeY + cursorY) * 100).rounded() / 100
        } else {
            combinedYesterday = 0
        }
    }

    // MARK: Export

    /// Model breakdown as CSV for clipboard / file export from the dashboard.
    func modelBreakdownCSV() -> String {
        var rows = ["Model,Claude USD,Cursor USD,Total USD"]
        for r in modelBreakdown {
            rows.append("\"\(Labels.model(r.model))\",\(r.claudeCost),\(r.cursorCost),\(r.total)")
        }
        let meta = "# AI usage — \(selectedRange.rawValue), local sessions as of \(asOfDate)"
        return ([meta] + rows).joined(separator: "\n")
    }

    /// The current ranking as CSV (legacy).
    func rankingCSV() -> String { modelBreakdownCSV() }

    // MARK: Dashboard computations

    private func recomputeDashboard() {
        let responses = responses(for: selectedRange)

        // Per-user totals across the range, split by tool, plus output (commits/lines).
        var claudeByUser: [String: (email: String, cost: Double)] = [:]
        var cursorByUser: [String: Double] = [:]
        var commitsByUser: [String: Int] = [:]
        var linesByUser: [String: Int] = [:]
        for resp in responses {
            for user in resp.data {
                let claude = claudeCostUsd(on: resp.asOfDate, userId: user.userId, response: resp)
                claudeByUser[user.userId] = (user.email, (claudeByUser[user.userId]?.cost ?? 0) + claude)
            }
            for (uid, cost) in cursorCostIndex[resp.asOfDate] ?? [:] {
                cursorByUser[uid] = (cursorByUser[uid] ?? 0) + cost
            }
            for (uid, act) in activityIndex[resp.asOfDate] ?? [:] {
                commitsByUser[uid] = (commitsByUser[uid] ?? 0) + act.commits
                linesByUser[uid] = (linesByUser[uid] ?? 0) + act.linesOfCode
            }
        }

        ranking = claudeByUser.map { uid, value in
            UserSpend(id: uid, email: value.email,
                      claudeCost: (value.cost * 100).rounded() / 100,
                      cursorCost: ((cursorByUser[uid] ?? 0) * 100).rounded() / 100,
                      commits: commitsByUser[uid] ?? 0,
                      linesOfCode: linesByUser[uid] ?? 0)
        }
        .sorted { $0.total > $1.total }

        // KPI cards (combined + per-tool + ROI).
        claudeTotal = (ranking.reduce(0) { $0 + $1.claudeCost } * 100).rounded() / 100
        cursorTotal = (ranking.reduce(0) { $0 + $1.cursorCost } * 100).rounded() / 100
        totalSpend = ((claudeTotal + cursorTotal) * 100).rounded() / 100
        totalCommits = ranking.reduce(0) { $0 + $1.commits }
        totalLinesOfCode = ranking.reduce(0) { $0 + $1.linesOfCode }
        totalConversations = responses.reduce(0) { sum, resp in
            sum + (activityIndex[resp.asOfDate]?[dataSource.currentUserId]?.conversations ?? 0)
        }
        totalMessages = responses.reduce(0) { sum, resp in
            sum + (activityIndex[resp.asOfDate]?[dataSource.currentUserId]?.messages ?? 0)
        }
        activeUsers = ranking.filter { $0.total > 0 }.count
        averagePerUser = activeUsers > 0 ? (totalSpend / Double(activeUsers) * 100).rounded() / 100 : 0

        // Per-tool time series for the stacked bar chart.
        var points: [ToolDailyPoint] = []
        for resp in responses {
            guard let date = Self.parse(resp.asOfDate) else { continue }
            let claudeDay = (resp.data.reduce(0) {
                $0 + claudeCostUsd(on: resp.asOfDate, userId: $1.userId, response: resp)
            } * 100).rounded() / 100
            let cursorDay = ((cursorCostIndex[resp.asOfDate]?.values.reduce(0, +) ?? 0) * 100).rounded() / 100
            points.append(ToolDailyPoint(id: "\(resp.asOfDate)|Claude", date: date, tool: "Claude", amount: claudeDay))
            points.append(ToolDailyPoint(id: "\(resp.asOfDate)|Cursor", date: date, tool: "Cursor", amount: cursorDay))
        }
        toolSeries = points

        // Per-model totals across the selected range.
        var claudeModels: [String: Double] = [:]
        var cursorModels: [String: Double] = [:]
        let me = dataSource.currentUserId
        for resp in responses {
            let skipClaude = cursorUsingAPI && (cursorCostIndex[resp.asOfDate]?[me] ?? 0) > 0
            if !skipClaude {
                for (model, cost) in claudeModelIndex[resp.asOfDate] ?? [:] {
                    claudeModels[model] = (claudeModels[model] ?? 0) + cost
                }
            }
            for (model, cost) in cursorModelIndex[resp.asOfDate] ?? [:] {
                cursorModels[model] = (cursorModels[model] ?? 0) + cost
            }
        }
        let allModels = Set(claudeModels.keys).union(cursorModels.keys)
        modelBreakdown = allModels.map { model in
            ModelSpend(
                model: model,
                claudeCost: ((claudeModels[model] ?? 0) * 100).rounded() / 100,
                cursorCost: ((cursorModels[model] ?? 0) * 100).rounded() / 100
            )
        }
        .sorted { $0.total > $1.total }
    }

    // MARK: Range helpers

    /// The subset of `history` matching the selected range (ordered oldest → newest).
    private func responses(for range: DateRange) -> [UserCostResponse] {
        switch range {
        case .today:
            return history.suffix(1).map { $0 }
        case .last7:
            return history.suffix(7).map { $0 }
        case .thisMonth:
            guard let asOf = history.last.flatMap({ Self.parse($0.asOfDate) }) else { return [] }
            return responsesInMonth(of: asOf)
        }
    }

    /// History entries in the same calendar month as `date`, up to and including it.
    private func responsesInMonth(of date: Date) -> [UserCostResponse] {
        let cal = Calendar.analytics
        let target = cal.dateComponents([.year, .month], from: date)
        return history.filter { resp in
            guard let d = Self.parse(resp.asOfDate) else { return false }
            let c = cal.dateComponents([.year, .month], from: d)
            return c.year == target.year && c.month == target.month && d <= date
        }
    }

    // MARK: Window sizing (month-aware)

    /// How many trailing days to fetch/scan: at least `historyDays` for the rolling dashboard
    /// views, AND at least the real number of days elapsed this month so month-to-date is complete.
    /// Calendar math gives the true elapsed-day count for any month/year — no fixed 30/31, no table.
    nonisolated static func windowDays(today: Date, historyDays: Int = historyDays, calendar: Calendar = .analytics) -> Int {
        max(historyDays, calendar.component(.day, from: today))
    }

    /// First day to scan: the rolling window OR the real first-of-`asOf`'s-month, whichever is
    /// earlier — guarantees every day of the current month is included (the 31st-day drop-off bug).
    nonisolated static func windowStart(asOf: Date, today: Date, historyDays: Int = historyDays, calendar: Calendar = .analytics) -> Date {
        let days = windowDays(today: today, historyDays: historyDays, calendar: calendar)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: asOf))!
        let rollingStart = calendar.date(byAdding: .day, value: -(days - 1), to: asOf)!
        return min(rollingStart, monthStart)
    }

    // MARK: Constants & formatting

    nonisolated private static let historyDays = 30
    /// Reuse a load result for this long across rapid window-opens (see `load(force:)`).
    private static let loadThrottle: TimeInterval = 15
    private var lastLoadedAt: Date?
    private static let budgetKey = "budget.monthly"
    private static let manualCursorKey = "cursor.manualMonthSpend"
    private static let usePersonalTokenKey = "cursor.usePersonalToken"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current   // local-time day boundaries (matches Calendar.analytics)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parse(_ s: String) -> Date? { dayFormatter.date(from: s) }
}
