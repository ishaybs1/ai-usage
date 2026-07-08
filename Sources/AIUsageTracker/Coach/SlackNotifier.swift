import Foundation

// MARK: - Slack delivery
//
// Posts a daily usage digest to a Slack Incoming Webhook. The webhook URL is user-supplied
// (Slack → Apps → Incoming Webhooks) and stored locally — see CoachViewModel.
//
// NOTE: a Slack webhook URL is a secret (anyone holding it can post to that channel). For the
// MVP it lives in UserDefaults; TODO: move it to the Keychain alongside the future Analytics
// API key.

enum SlackError: LocalizedError {
    case invalidWebhookURL
    case badStatus(Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidWebhookURL:
            return "That doesn't look like a valid Slack webhook URL."
        case let .badStatus(code, body):
            return "Slack rejected the message (HTTP \(code)): \(body)"
        }
    }
}

struct SlackNotifier {
    var session: URLSession = .shared

    /// POST `{ "text": ... }` to the webhook. Throws on a non-2xx response.
    func send(text: String, webhookURLString: String) async throws {
        guard let url = URL(string: webhookURLString),
              url.scheme == "https",
              url.host?.contains("slack.com") == true else {
            throw SlackError.invalidWebhookURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw SlackError.badStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Build the digest text. Kept pure (no I/O) so it can be unit-tested headlessly.
    static func digestText(
        asOfDate: String,
        claudeToday: Double,
        cursorToday: Double,
        combinedToday: Double,
        combinedMonth: Double,
        topProductLabel: String?,
        tip: CoachTip
    ) -> String {
        var lines: [String] = []
        lines.append(":robot_face: *Your AI usage* — data as of \(asOfDate)")
        lines.append("• Today: *\(Money.string(combinedToday))*    • This month: *\(Money.string(combinedMonth))*")
        lines.append("• By tool today: Claude \(Money.string(claudeToday)) · Cursor \(Money.string(cursorToday))")
        if let topProductLabel {
            lines.append("• Biggest Claude line today: \(topProductLabel)")
        }
        lines.append(":bulb: *Tip #\(tip.rank): \(tip.title)* — \(tip.detail)")
        return lines.joined(separator: "\n")
    }
}
