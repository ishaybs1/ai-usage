import Foundation

// MARK: - User activity models (the spec's secondary endpoint)
//
// `GET /users?date=YYYY-MM-DD&limit=N` — per-user engagement (conversations, messages,
// commits, lines of code). Joined to cost, this turns "how much did we spend" into "what did
// the spend produce" — cost per commit / per active day. Same delayed-data semantics as cost.

struct UserActivityResponse: Codable, Equatable {
    let data: [UserActivity]
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

/// Per-user engagement for a day.
struct UserActivity: Codable, Equatable, Identifiable {
    let userId: String
    let email: String
    let conversations: Int
    let messages: Int
    let commits: Int
    let linesOfCode: Int

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case conversations
        case messages
        case commits
        case linesOfCode = "lines_of_code"
    }
}
