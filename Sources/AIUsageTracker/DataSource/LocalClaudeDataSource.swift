import Foundation

// MARK: - Local Claude data source
//
// Implements AnalyticsDataSource by scanning ~/.claude/projects JSONL session files.

final class LocalClaudeDataSource: AnalyticsDataSource {

    private let scanner: LocalUsageScanner

    init(scanner: LocalUsageScanner = .shared) {
        self.scanner = scanner
    }

    var currentUserId: String { "local_user" }

    func fetchUserCosts(date: Date) async throws -> UserCostResponse {
        // `asOfDate` MUST be the queried day, because the ViewModel keys/filters everything by
        // it (per-day cost index, month-to-date). Stamping every day with the latest day would
        // make all days fall into "this month".
        let key = LocalUsageScanner.dayKey(date)
        let agg = await scanner.aggregate(for: key)

        let user = UserCost(
            userId: currentUserId,
            email: localEmail,
            actorType: "user",
            costUsd: agg.claudeCost,
            breakdown: CostBreakdown(
                byProduct: agg.claudeByProduct.isEmpty ? nil : agg.claudeByProduct,
                byModel: agg.claudeByModel.isEmpty ? nil : agg.claudeByModel,
                byCostType: agg.claudeCost > 0 ? ["tokens": agg.claudeCost] : nil
            )
        )
        return UserCostResponse(data: [user], asOfDate: key, hasMore: false, nextCursor: nil)
    }

    private var localEmail: String {
        let name = NSFullUserName().isEmpty ? "me" : NSFullUserName().lowercased().replacingOccurrences(of: " ", with: ".")
        return "\(name)@local"
    }
}
