import Foundation

// MARK: - Anthropic Claude Enterprise Analytics API — response models
//
// These structs mirror the real "Per-user cost" endpoint response shape EXACTLY
// (see claude-code-instructions.md → "API Schema"). Wire keys are snake_case and are
// mapped via CodingKeys so the Swift side can use idiomatic camelCase. The mock data
// source and the (future) live data source both produce/consume these same types, so
// switching to the live API never changes the model layer.

/// Top-level response from the per-user cost endpoint.
///
/// ```json
/// { "data": [...], "as_of_date": "2026-06-06", "has_more": false, "next_cursor": null }
/// ```
struct UserCostResponse: Codable, Equatable {
    /// One entry per actor (user / service account) in the queried window.
    let data: [UserCost]
    /// The date the data is current as of (wire format "YYYY-MM-DD"). The API is not
    /// real-time — it refreshes every ~4h with up to a 3-day delay — so this is the
    /// authoritative "today" and MUST be surfaced in the UI ("Data as of <date>").
    let asOfDate: String
    /// Cursor-based pagination: true when more pages are available.
    let hasMore: Bool
    /// Opaque cursor for the next page, or nil when `hasMore` is false.
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case asOfDate = "as_of_date"
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

/// Per-actor cost for the queried window.
struct UserCost: Codable, Equatable, Identifiable {
    /// Stable analytics user id (e.g. "user_abc123"). Used as the `Identifiable` id.
    let userId: String
    /// Actor email (also used as a human-readable label).
    let email: String
    /// Actor type, e.g. "user". Kept as a String (not an enum) so unknown future
    /// actor types — e.g. "service_account" — never break decoding.
    let actorType: String
    /// Total USD spend for this actor over the window.
    let costUsd: Double
    /// Optional breakdowns by product / model / cost type.
    let breakdown: CostBreakdown?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case actorType = "actor_type"
        case costUsd = "cost_usd"
        case breakdown
    }
}

/// Spend broken down along several dimensions. Each map is keyed by the API's own
/// dynamic keys (product name, model id, cost-type name) → USD. Dictionaries (rather
/// than fixed fields) match how the real API returns these and tolerate new
/// products/models without model changes.
struct CostBreakdown: Codable, Equatable {
    /// e.g. "claude_chat", "claude_code", "cowork" → USD.
    let byProduct: [String: Double]?
    /// e.g. "claude-opus-4-8", "claude-sonnet-4-6" → USD.
    let byModel: [String: Double]?
    /// e.g. "tokens", "web_search", "code_execution" → USD.
    let byCostType: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case byProduct = "by_product"
        case byModel = "by_model"
        case byCostType = "by_cost_type"
    }
}
