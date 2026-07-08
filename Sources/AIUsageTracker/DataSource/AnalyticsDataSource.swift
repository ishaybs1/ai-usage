import Foundation

// MARK: - Data layer abstraction
//
// Per the build doc (principle #2): everything goes through ONE interface. The app talks
// only to `AnalyticsDataSource`; swapping mock → live is a single line in the ViewModel init.

/// Limits enforced by the real Analytics API. Kept in one place so both the mock and the
/// live source apply identical rules.
enum AnalyticsAPILimits {
    /// Maximum span of a single cost query.
    static let maxQueryWindowDays = 31
    /// How far back cost history is retained.
    static let maxHistoryDays = 365
    /// Earliest date for which any data exists.
    static let dataStartDate = DateComponents(calendar: .analytics, year: 2026, month: 1, day: 1).date!
    /// Requests allowed per minute.
    static let rateLimitPerMinute = 60
    /// Worst-case delay before a day's data becomes available. So "today" in practice is
    /// `today() - dataDelayDays`, surfaced to the UI as the response's `as_of_date`.
    static let dataDelayDays = 3

    /// The latest day for which data is "available": today minus the data delay, computed at
    /// runtime so the "Data as of …" date tracks the calendar (and refreshes on reload) rather
    /// than being frozen. The mocks anchor their generated history to this date.
    static var latestAvailableDate: Date {
        let cal = Calendar.analytics
        return cal.date(byAdding: .day, value: -dataDelayDays, to: cal.startOfDay(for: Date()))!
    }
}

/// Errors the data layer can surface.
enum AnalyticsError: Error, LocalizedError, Equatable {
    /// The requested range exceeds `maxQueryWindowDays`.
    case queryWindowTooLarge(requestedDays: Int, maxDays: Int)
    /// The live API path isn't wired up yet (MVP runs on `MockDataSource`).
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case let .queryWindowTooLarge(requested, max):
            return "Query window of \(requested) days exceeds the maximum of \(max) days."
        case let .notImplemented(what):
            return "\(what) is not implemented yet."
        }
    }
}

/// The single interface the rest of the app depends on.
///
/// Implementations: `MockDataSource` (deterministic demo data) and, later,
/// `LiveAnalyticsDataSource` (real HTTP). Both honor the same semantics, so nothing above
/// this layer knows or cares which one is wired in.
protocol AnalyticsDataSource {
    /// The actor id representing the signed-in user ("me") for the personal menu-bar view.
    /// In the live source this comes from the identity tied to the Analytics API key.
    var currentUserId: String { get }

    /// Per-user costs for a single calendar day.
    ///
    /// `date` is the requested day. Because data is delayed, callers may pass the device's
    /// "today"; the implementation clamps to the latest available day and reports the actual
    /// data date in `UserCostResponse.asOfDate` — which is the authoritative "today".
    func fetchUserCosts(date: Date) async throws -> UserCostResponse
}

extension AnalyticsDataSource {
    /// Convenience: fetch a contiguous, inclusive range of days. Default implementation loops
    /// day-by-day over `fetchUserCosts(date:)`; the live source may override with a single
    /// ranged request. Enforces the 31-day window limit.
    func fetchUserCosts(in range: ClosedRange<Date>) async throws -> [UserCostResponse] {
        let cal = Calendar.analytics
        let days = (cal.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0) + 1
        guard days <= AnalyticsAPILimits.maxQueryWindowDays else {
            throw AnalyticsError.queryWindowTooLarge(
                requestedDays: days,
                maxDays: AnalyticsAPILimits.maxQueryWindowDays
            )
        }
        var responses: [UserCostResponse] = []
        var day = range.lowerBound
        while day <= range.upperBound {
            responses.append(try await fetchUserCosts(date: day))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return responses
    }
}

// MARK: - Shared calendar

extension Calendar {
    /// Gregorian calendar in the Mac's LOCAL time zone, so "day" and "month" boundaries match the
    /// user's wall clock (a session at 1 AM local counts as today, not yesterday; the budget month
    /// is the local calendar month). Every day-key formatter below uses the same zone so bucketing
    /// and month math agree. Captured once at launch — a time-zone change takes effect on restart.
    static let analytics: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal
    }()
}
