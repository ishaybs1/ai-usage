import Foundation

// MARK: - Cursor data layer
//
// Same pattern as AnalyticsDataSource: one protocol, a deterministic mock, and (later) a live
// source. Uses the SAME user ids/emails as the Claude mock so the two can be joined per user.

protocol CursorDataSource {
    func fetchCursorUsage(date: Date) async throws -> CursorUsageResponse
}

extension CursorDataSource {
    /// Inclusive day range; loops day-by-day (mirrors AnalyticsDataSource).
    func fetchCursorUsage(in range: ClosedRange<Date>) async throws -> [CursorUsageResponse] {
        let cal = Calendar.analytics
        var responses: [CursorUsageResponse] = []
        var day = range.lowerBound
        while day <= range.upperBound {
            responses.append(try await fetchCursorUsage(date: day))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return responses
    }
}

/// Deterministic mock Cursor usage for the same 12 users as `MockDataSource`.
final class MockCursorDataSource: CursorDataSource {

    let latestAvailableDate = AnalyticsAPILimits.latestAvailableDate
    private let historyDays = 30
    private let earliestAvailableDate: Date
    private let usageByDay: [String: [CursorUsage]]

    /// (id, email, daily mean spend, daily mean fast-requests). Same identities as the Claude
    /// mock; Cursor spend is generally lower (most usage is plan-included).
    private static let users: [(id: String, email: String, meanCost: Double, meanFast: Int)] = [
        ("user_dana",   "dana@company.com",   8.0, 120),
        ("user_marcus", "marcus@company.com", 6.5, 95),
        ("user_ishay",  "ishay@company.com",  5.0, 80),
        ("user_lena",   "lena@company.com",   2.0, 35),
        ("user_omar",   "omar@company.com",   3.5, 60),
        ("user_priya",  "priya@company.com",  1.2, 20),
        ("user_tom",    "tom@company.com",    2.6, 45),
        ("user_sara",   "sara@company.com",   0.8, 14),
        ("user_kenji",  "kenji@company.com",  3.0, 52),
        ("user_amara",  "amara@company.com",  0.9, 16),
        ("user_leo",    "leo@company.com",    0.6, 10),
        ("user_mei",    "mei@company.com",    1.4, 24),
    ]

    init() {
        let cal = Calendar.analytics
        let earliest = cal.date(byAdding: .day, value: -(historyDays - 1), to: latestAvailableDate)!
        self.earliestAvailableDate = earliest

        var map: [String: [CursorUsage]] = [:]
        var day = earliest
        var dayOffset = 0
        while day <= latestAvailableDate {
            let key = Self.dayFormatter.string(from: day)
            map[key] = Self.users.enumerated().map { idx, u in
                // Seed offset (700_001) keeps Cursor's stream independent of Claude's but still
                // fully deterministic.
                var rng = SeededGenerator(seed: UInt64(idx &* 700_001 &+ dayOffset &+ 1))
                let jitter = Double.random(in: 0.4...1.6, using: &rng)
                let cost = (min(max(u.meanCost * jitter, 0), 40) * 100).rounded() / 100
                let fast = max(0, Int((Double(u.meanFast) * jitter).rounded()))
                let total = fast + Int.random(in: 30...120, using: &rng)
                return CursorUsage(userId: u.id, email: u.email, costUsd: cost,
                                   fastRequests: fast, totalRequests: total)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            dayOffset += 1
        }
        self.usageByDay = map
    }

    func fetchCursorUsage(date: Date) async throws -> CursorUsageResponse {
        let clamped = min(max(date, earliestAvailableDate), latestAvailableDate)
        let key = Self.dayFormatter.string(from: clamped)
        return CursorUsageResponse(data: usageByDay[key] ?? [], asOfDate: key,
                                   hasMore: false, nextCursor: nil)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current   // local-time day boundaries (matches Calendar.analytics)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
