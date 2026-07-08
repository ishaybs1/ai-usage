import Foundation

// MARK: - Local activity data source
//
// Derives engagement stats from parsed local sessions (conversations + messages).

final class LocalActivityDataSource: ActivityDataSource {

    private let scanner: LocalUsageScanner

    init(scanner: LocalUsageScanner = .shared) {
        self.scanner = scanner
    }

    func fetchUserActivity(date: Date) async throws -> UserActivityResponse {
        let key = LocalUsageScanner.dayKey(date)
        let agg = await scanner.aggregate(for: key)

        let conversations = agg.claudeSessions.count + agg.cursorSessions.count
        let messages = agg.claudeMessages + agg.cursorMessages
        let user = UserActivity(
            userId: "local_user",
            email: localEmail,
            conversations: conversations,
            messages: messages,
            commits: 0,
            linesOfCode: 0
        )
        return UserActivityResponse(data: [user], asOfDate: key, hasMore: false, nextCursor: nil)
    }

    private var localEmail: String {
        let name = NSFullUserName().isEmpty ? "me" : NSFullUserName().lowercased().replacingOccurrences(of: " ", with: ".")
        return "\(name)@local"
    }
}
