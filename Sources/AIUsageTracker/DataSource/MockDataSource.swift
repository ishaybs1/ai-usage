import Foundation

// MARK: - Deterministic PRNG
//
// SplitMix64 — a tiny, high-quality seedable generator. Seeding it identically yields an
// identical stream, which is how the demo looks the same on every run (doc requirement).

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Mock data source

/// Generates a realistic, fully deterministic dataset in the exact `UserCostResponse` shape.
///
/// - ~12 fictional users with a skewed spend distribution (a couple of heavy users, a few
///   medium, most light), daily spend clamped to the $1–$40 range.
/// - 30 days of history so charts are full.
/// - A fixed anchor date (the "latest available" day) so every run is identical.
final class MockDataSource: AnalyticsDataSource {

    /// "Me" — the signed-in user shown in the menu bar. Matches the doc's sample (ishay).
    let currentUserId = "user_ishay"

    /// The latest day for which data is "available": today minus the 3-day delay, computed at
    /// runtime so the "Data as of …" date tracks the calendar and refreshes on reload. The
    /// per-day values stay deterministic because they're seeded by day-offset (today is always
    /// the last offset), so "today's" numbers are stable even as the date advances.
    let latestAvailableDate = AnalyticsAPILimits.latestAvailableDate

    /// Days of history to generate.
    private let historyDays = 30

    /// Pre-generated dataset, keyed by "yyyy-MM-dd" → that day's per-user costs.
    private let costsByDay: [String: [UserCost]]

    /// Inclusive earliest day we hold data for.
    private let earliestAvailableDate: Date

    init() {
        let cal = Calendar.analytics
        let latest = latestAvailableDate
        let earliest = cal.date(byAdding: .day, value: -(historyDays - 1), to: latest)!
        self.earliestAvailableDate = earliest

        // Build the dataset deterministically, one entry per (user, day).
        var map: [String: [UserCost]] = [:]
        var day = earliest
        var dayOffset = 0
        while day <= latest {
            let key = Self.dayFormatter.string(from: day)
            map[key] = MockDataSource.users.enumerated().map { userIndex, user in
                Self.makeUserCost(for: user, userIndex: userIndex, dayOffset: dayOffset)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            dayOffset += 1
        }
        self.costsByDay = map
    }

    // MARK: AnalyticsDataSource

    func fetchUserCosts(date: Date) async throws -> UserCostResponse {
        // Clamp the requested day into the window we actually hold data for. Asking for a
        // future/too-recent day yields the latest available day (mirrors the data delay);
        // asking before our history yields the earliest day we have.
        let clamped = min(max(date, earliestAvailableDate), latestAvailableDate)
        let key = Self.dayFormatter.string(from: clamped)
        let data = costsByDay[key] ?? []
        // Single page for the mock (12 users). Pagination is exercised in the live source.
        return UserCostResponse(data: data, asOfDate: key, hasMore: false, nextCursor: nil)
    }

    // MARK: - Demo users

    /// A fictional user with a spend "tier" that drives its daily average.
    private struct DemoUser {
        let id: String
        let name: String
        let email: String
        /// Average daily spend in USD for this user (before per-day jitter).
        let dailyMean: Double
        /// Bias toward claude_code vs claude_chat (1.0 = code-heavy engineer, 0.0 = chat-only).
        let codeBias: Double
    }

    /// 12 users with a deliberately skewed distribution: 2 heavy, 3 medium, 7 light.
    private static let users: [DemoUser] = [
        // Heavy
        DemoUser(id: "user_dana",   name: "Dana Cohen",      email: "dana@company.com",    dailyMean: 31, codeBias: 0.85),
        DemoUser(id: "user_marcus", name: "Marcus Reid",     email: "marcus@company.com",  dailyMean: 27, codeBias: 0.80),
        // Medium
        DemoUser(id: "user_ishay",  name: "Ishay Ben-Sasson", email: "ishay@company.com",  dailyMean: 13, codeBias: 0.65),
        DemoUser(id: "user_lena",   name: "Lena Hoffmann",   email: "lena@company.com",    dailyMean: 11, codeBias: 0.40),
        DemoUser(id: "user_omar",   name: "Omar Haddad",     email: "omar@company.com",    dailyMean: 10, codeBias: 0.55),
        // Light
        DemoUser(id: "user_priya",  name: "Priya Nair",      email: "priya@company.com",   dailyMean: 4.5, codeBias: 0.30),
        DemoUser(id: "user_tom",    name: "Tom Becker",      email: "tom@company.com",     dailyMean: 3.8, codeBias: 0.50),
        DemoUser(id: "user_sara",   name: "Sara Lindqvist",  email: "sara@company.com",    dailyMean: 3.2, codeBias: 0.20),
        DemoUser(id: "user_kenji",  name: "Kenji Watanabe",  email: "kenji@company.com",   dailyMean: 2.9, codeBias: 0.60),
        DemoUser(id: "user_amara",  name: "Amara Okafor",    email: "amara@company.com",   dailyMean: 2.4, codeBias: 0.35),
        DemoUser(id: "user_leo",    name: "Leo Santos",      email: "leo@company.com",     dailyMean: 1.9, codeBias: 0.25),
        DemoUser(id: "user_mei",    name: "Mei Lin",         email: "mei@company.com",     dailyMean: 1.5, codeBias: 0.45),
    ]

    // MARK: - Generation

    /// Build one user's cost entry for one day, deterministically seeded by (user, day).
    private static func makeUserCost(for user: DemoUser, userIndex: Int, dayOffset: Int) -> UserCost {
        // Seed uniquely per (user, day) so the same date always reproduces the same numbers.
        var rng = SeededGenerator(seed: UInt64(userIndex &* 100_003 &+ dayOffset &+ 1))

        // Daily cost: mean × jitter in [0.45, 1.55], clamped to the $1–$40 range.
        let jitter = Double.random(in: 0.45...1.55, using: &rng)
        let rawCost = user.dailyMean * jitter
        let cost = (min(max(rawCost, 1.0), 40.0) * 100).rounded() / 100

        let breakdown = makeBreakdown(cost: cost, codeBias: user.codeBias, rng: &rng)

        return UserCost(
            userId: user.id,
            email: user.email,
            actorType: "user",
            costUsd: cost,
            breakdown: breakdown
        )
    }

    /// Split a day's cost across products / models / cost types. Each split sums exactly to
    /// `cost` (the remainder is absorbed by the largest bucket) so the UI bars add up.
    private static func makeBreakdown(cost: Double, codeBias: Double, rng: inout SeededGenerator) -> CostBreakdown {
        // by_product: code vs chat governed by the user's bias, with a little "cowork".
        let coworkShare = Double.random(in: 0.03...0.12, using: &rng)
        let nonCowork = 1 - coworkShare
        let codeShare = nonCowork * codeBias
        let chatShare = nonCowork * (1 - codeBias)
        let byProduct = allocate(cost, weights: [
            "claude_code": codeShare,
            "claude_chat": chatShare,
            "cowork": coworkShare,
        ])

        // by_model: opus is the larger share; sonnet the rest.
        let opusShare = Double.random(in: 0.55...0.80, using: &rng)
        let byModel = allocate(cost, weights: [
            "claude-opus-4-8": opusShare,
            "claude-sonnet-4-6": 1 - opusShare,
        ])

        // by_cost_type: overwhelmingly tokens, small web_search + code_execution.
        let webShare = Double.random(in: 0.02...0.06, using: &rng)
        let execShare = Double.random(in: 0.01...0.04, using: &rng)
        let byCostType = allocate(cost, weights: [
            "web_search": webShare,
            "code_execution": execShare,
            "tokens": max(0, 1 - webShare - execShare),
        ])

        return CostBreakdown(byProduct: byProduct, byModel: byModel, byCostType: byCostType)
    }

    /// Distribute `total` across keys by (normalized) weight, rounded to cents, with the
    /// rounding remainder assigned to the heaviest key so the parts sum exactly to `total`.
    private static func allocate(_ total: Double, weights: [String: Double]) -> [String: Double] {
        let sum = weights.values.reduce(0, +)
        guard sum > 0 else { return weights.mapValues { _ in 0 } }
        var result: [String: Double] = [:]
        var allocated = 0.0
        // Sort for a deterministic "heaviest" pick. The key tiebreaker matters: Swift's
        // `sorted` is NOT stable, so on equal weights (e.g. codeBias == 0.5) the remainder
        // would otherwise land on different keys across runs and break determinism.
        let sorted = weights.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (key, weight) in sorted {
            let cents = ((total * weight / sum) * 100).rounded() / 100
            result[key] = cents
            allocated += cents
        }
        if let heaviest = sorted.first?.key {
            let remainder = ((total - allocated) * 100).rounded() / 100
            result[heaviest] = ((result[heaviest] ?? 0) + remainder)
            // Guard against -0.0 / tiny negative noise.
            result[heaviest] = max(0, (result[heaviest]! * 100).rounded() / 100)
        }
        return result
    }

    // MARK: - Formatting

    /// "yyyy-MM-dd" in UTC — the API's wire date format.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current   // local-time day boundaries (matches Calendar.analytics)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
