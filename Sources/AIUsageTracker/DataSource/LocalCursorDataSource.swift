import Foundation

// MARK: - Local Cursor data source
//
// Implements CursorDataSource by reading token counts from Cursor's state.vscdb.

final class LocalCursorDataSource: CursorDataSource {

    private let scanner: LocalUsageScanner

    init(scanner: LocalUsageScanner = .shared) {
        self.scanner = scanner
    }

    func fetchCursorUsage(date: Date) async throws -> CursorUsageResponse {
        let key = LocalUsageScanner.dayKey(date)
        let agg = await scanner.aggregate(for: key)

        let user = CursorUsage(
            userId: "local_user",
            email: localEmail,
            costUsd: agg.cursorCost,
            fastRequests: agg.cursorMessages,
            totalRequests: agg.cursorMessages
        )
        return CursorUsageResponse(data: [user], asOfDate: key, hasMore: false, nextCursor: nil)
    }

    private var localEmail: String {
        let name = NSFullUserName().isEmpty ? "me" : NSFullUserName().lowercased().replacingOccurrences(of: " ", with: ".")
        return "\(name)@local"
    }
}
