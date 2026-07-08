import Foundation

// MARK: - Local macOS notifications
//
// Zero-setup daily digest: posts a Notification Center banner on this Mac. No webhook/URL needed
// (unlike Slack).
//
// We deliver via `osascript … display notification` rather than UNUserNotificationCenter, because
// UN silently refuses to deliver from an UNSIGNED app bundle (authorization is denied and add()
// drops the request — which is why the first cut didn't fire). AppleScript's `display notification`
// works from any process with no signing, entitlement, or permission prompt.

enum LocalNotifier {
    /// osascript ships with macOS, so delivery is always available.
    static var isAvailable: Bool { true }

    /// No-op — `display notification` needs no authorization (kept for call-site compatibility).
    static func requestAuthorization() {}

    /// Post a Notification Center banner now.
    static func post(title: String, body: String) {
        let script = "display notification \(escape(body)) with title \(escape(title))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    /// Wrap a string as an AppleScript double-quoted literal (escape backslash and quote).
    private static func escape(_ s: String) -> String {
        let inner = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(inner)\""
    }
}
