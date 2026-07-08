import Foundation

// MARK: - Cursor usage models
//
// Cursor is a SEPARATE provider from Anthropic, so it gets its own models rather than being
// forced into the Claude analytics schema (principle #1: don't invent a shape on an existing
// API). This mirrors the shape of Cursor's Teams Admin "daily usage" data: per-user spend and
// a couple of request counts. The app then combines Claude + Cursor into an "all tools" view.

/// Top-level response from the Cursor daily-usage endpoint (mock).
struct CursorUsageResponse: Codable, Equatable {
    let data: [CursorUsage]
    /// Same delayed-data semantics as Claude — surface it, don't assume "now".
    let asOfDate: String
    let hasMore: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case asOfDate = "as_of_date"
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

/// Per-user Cursor usage for a day.
struct CursorUsage: Codable, Equatable, Identifiable {
    let userId: String
    let email: String
    /// Usage-based spend in USD (premium/fast requests beyond plan).
    let costUsd: Double
    /// "Fast"/premium model requests — Cursor's primary metered unit.
    let fastRequests: Int
    /// All requests (fast + included), for context.
    let totalRequests: Int

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case costUsd = "cost_usd"
        case fastRequests = "fast_requests"
        case totalRequests = "total_requests"
    }
}
