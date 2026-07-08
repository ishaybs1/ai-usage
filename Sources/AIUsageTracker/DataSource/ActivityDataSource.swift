import Foundation

// MARK: - Activity data layer
//
// Same shape as AnalyticsDataSource / CursorDataSource: one protocol, a deterministic mock,
// and (later) a live source. Uses the SAME user ids/emails so activity joins to cost per user.

protocol ActivityDataSource {
    func fetchUserActivity(date: Date) async throws -> UserActivityResponse
}

extension ActivityDataSource {
    /// Inclusive day range; loops day-by-day.
    func fetchUserActivity(in range: ClosedRange<Date>) async throws -> [UserActivityResponse] {
        let cal = Calendar.analytics
        var responses: [UserActivityResponse] = []
        var day = range.lowerBound
        while day <= range.upperBound {
            responses.append(try await fetchUserActivity(date: day))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return responses
    }
}

/// Deterministic mock activity for the same 12 users as `MockDataSource`.
final class MockActivityDataSource: ActivityDataSource {

    let latestAvailableDate = AnalyticsAPILimits.latestAvailableDate
    private let historyDays = 30
    private let earliestAvailableDate: Date
    private let activityByDay: [String: [UserActivity]]

    /// (id, email, mean commits/day). Heavier coders commit more; light users mostly chat.
    private static let users: [(id: String, email: String, meanCommits: Double)] = [
        ("user_dana",   "dana@company.com",   9),
        ("user_marcus", "marcus@company.com", 8),
        ("user_ishay",  "ishay@company.com",  5),
        ("user_lena",   "lena@company.com",   2),
        ("user_omar",   "omar@company.com",   4),
        ("user_priya",  "priya@company.com",  1),
        ("user_tom",    "tom@company.com",    3),
        ("user_sara",   "sara@company.com",   1),
        ("user_kenji",  "kenji@company.com",  4),
        ("user_amara",  "amara@company.com",  1),
        ("user_leo",    "leo@company.com",    1),
        ("user_mei",    "mei@company.com",    2),
    ]

    init() {
        let cal = Calendar.analytics
        let earliest = cal.date(byAdding: .day, value: -(historyDays - 1), to: latestAvailableDate)!
        self.earliestAvailableDate = earliest

        var map: [String: [UserActivity]] = [:]
        var day = earliest
        var dayOffset = 0
        while day <= latestAvailableDate {
            let key = Self.dayFormatter.string(from: day)
            map[key] = Self.users.enumerated().map { idx, u in
                // Seed offset (500_009) keeps activity independent of cost/Cursor but deterministic.
                var rng = SeededGenerator(seed: UInt64(idx &* 500_009 &+ dayOffset &+ 1))
                let jitter = Double.random(in: 0.3...1.7, using: &rng)
                let commits = max(0, Int((u.meanCommits * jitter).rounded()))
                let lines = commits * Int.random(in: 40...160, using: &rng)
                let messages = commits * Int.random(in: 6...14, using: &rng) + Int.random(in: 2...20, using: &rng)
                let conversations = max(1, messages / Int.random(in: 4...8, using: &rng))
                return UserActivity(userId: u.id, email: u.email,
                                    conversations: conversations, messages: messages,
                                    commits: commits, linesOfCode: lines)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            dayOffset += 1
        }
        self.activityByDay = map
    }

    func fetchUserActivity(date: Date) async throws -> UserActivityResponse {
        let clamped = min(max(date, earliestAvailableDate), latestAvailableDate)
        let key = Self.dayFormatter.string(from: clamped)
        return UserActivityResponse(data: activityByDay[key] ?? [], asOfDate: key,
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
