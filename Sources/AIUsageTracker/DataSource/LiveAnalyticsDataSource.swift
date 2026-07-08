import Foundation

// MARK: - Live data source (NOT implemented in the MVP)
//
// This is the production path against Anthropic's Claude Enterprise Analytics API. It has the
// SAME signatures as `MockDataSource`, so going live is a one-line change in the ViewModel:
//
//     init(dataSource: AnalyticsDataSource = MockDataSource())   // ← swap to LiveAnalyticsDataSource()
//
// Do NOT implement the real network call yet — the MVP demo runs entirely on mock data.

/// Real HTTP-backed implementation of `AnalyticsDataSource`. Stubbed for now.
final class LiveAnalyticsDataSource: AnalyticsDataSource {

    /// Base URL for the analytics endpoints.
    private let baseURL = URL(string: "https://api.anthropic.com/v1/organizations/analytics/")!

    /// URLSession used for requests (the only place networking lives, per the doc).
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// In production this is resolved from the identity tied to the Analytics API key.
    /// TODO: derive the signed-in user id from the org/key identity (or a config value).
    let currentUserId: String = ""

    func fetchUserCosts(date: Date) async throws -> UserCostResponse {
        // TODO: real API call.
        //
        // Sketch of the production implementation:
        //   1. Build the request:
        //        GET <baseURL>users?date=YYYY-MM-DD&limit=N   (or the per-user cost endpoint)
        //   2. Auth header — a DEDICATED Analytics API key, NOT the regular sk-ant-... key:
        //        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        //      TODO: load `apiKey` from the macOS Keychain (preferred) or an env var.
        //            NEVER hardcode the key. e.g. KeychainStore.read("ANTHROPIC_ANALYTICS_API_KEY").
        //   3. let (data, response) = try await session.data(for: request)
        //   4. Validate the HTTP status; respect the 60 req/min rate limit (back off on 429).
        //   5. Decode into `UserCostResponse` (same Codable models the mock uses).
        //   6. Follow pagination: while response.hasMore, refetch with `next_cursor` and append.
        //   7. "Today" = the returned `as_of_date`, never the device date.
        throw AnalyticsError.notImplemented("LiveAnalyticsDataSource.fetchUserCosts")
    }
}
