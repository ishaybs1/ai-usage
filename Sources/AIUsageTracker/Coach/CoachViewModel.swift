import Foundation
import AppKit

// MARK: - CoachViewModel
//
// Owns the cost-coaching UI state: the tips, the personalized insight, the Slack digest
// settings (persisted), the daily scheduler, and the bridge to the existing `coach.sh` tool.

@MainActor
final class CoachViewModel: ObservableObject {

    /// Source of the spend numbers shown/sent. Held strongly; `UsageViewModel` doesn't
    /// reference back, so there's no retain cycle.
    private let usage: UsageViewModel
    private let notifier = SlackNotifier()

    // Persisted settings (UserDefaults).
    /// Local macOS notification — the zero-setup default (no URL needed).
    @Published var notifyOnMac: Bool {
        didSet { persist(); if notifyOnMac { LocalNotifier.requestAuthorization() }; rescheduleDaily() }
    }
    @Published var slackEnabled: Bool { didSet { persist(); rescheduleDaily() } }
    @Published var webhookURL: String { didSet { persist() } }
    @Published var sendHour: Int { didSet { persist(); rescheduleDaily() } }

    @Published private(set) var lastStatus: String?
    @Published private(set) var isSending = false

    private var dailyTimer: Timer?

    private enum Keys {
        static let notify = "coach.notify.mac"
        static let enabled = "coach.slack.enabled"
        static let webhook = "coach.slack.webhook"
        static let hour = "coach.slack.hour"
    }

    init(usage: UsageViewModel) {
        self.usage = usage
        let d = UserDefaults.standard
        self.notifyOnMac = d.object(forKey: Keys.notify) as? Bool ?? true   // on by default
        self.slackEnabled = d.bool(forKey: Keys.enabled)
        self.webhookURL = d.string(forKey: Keys.webhook) ?? ""
        self.sendHour = d.object(forKey: Keys.hour) as? Int ?? 9
        if notifyOnMac { LocalNotifier.requestAuthorization() }
        rescheduleDaily()
    }

    // MARK: Content

    var tips: [CoachTip] { CoachAdvisor.tips(on: Date()) }

    /// The day the expensive-sessions list covers, and those sessions (richest first), each
    /// paired with a data-driven coaching line. Recomputed on every usage refresh.
    var topSessionsDay: String { usage.topSessionsDay }
    var topSessions: [(session: SessionCost, advice: String)] {
        usage.topSessionsToday.map { ($0, CoachAdvisor.coaching(for: $0)) }
    }

    var insight: String? {
        CoachAdvisor.insight(
            productBreakdown: usage.myProductBreakdown,
            modelBreakdown: usage.myModelBreakdown,
            today: usage.mySpendToday
        )
    }

    /// Slack is usable only with a valid webhook URL.
    var canSend: Bool {
        !webhookURL.isEmpty && URL(string: webhookURL)?.host?.contains("slack.com") == true
    }
    /// Whether "Send test now" can do anything — a local notification needs no URL.
    var canDeliver: Bool { notifyOnMac || canSend }

    // MARK: Sending

    /// Deliver the digest now to every enabled channel (explicit action or the daily scheduler).
    func sendNow() async {
        isSending = true
        defer { isSending = false }
        let tip = tips.first ?? CoachTip(rank: 1, title: "", detail: "", wrong: "", right: "")
        var results: [String] = []

        // 1) Local notification — the no-setup default.
        if notifyOnMac {
            LocalNotifier.post(
                title: "AI usage — \(Money.string(usage.combinedToday)) today",
                body: "This month \(Money.string(usage.combinedThisMonth)). Tip: \(tip.title)."
            )
            results.append("notification sent")
        }

        // 2) Slack — only if enabled and a valid webhook is set.
        if slackEnabled, canSend {
            let topProduct = usage.myProductBreakdown.max { $0.value < $1.value }
                .map { "\(Labels.product($0.key)) (\(Money.string($0.value)))" }
            let text = SlackNotifier.digestText(
                asOfDate: usage.asOfDate,
                claudeToday: usage.mySpendToday,
                cursorToday: usage.myCursorToday,
                combinedToday: usage.combinedToday,
                combinedMonth: usage.combinedThisMonth,
                topProductLabel: topProduct,
                tip: tip
            )
            do {
                try await notifier.send(text: text, webhookURLString: webhookURL)
                results.append("Slack sent")
            } catch {
                results.append("Slack failed: \(error.localizedDescription)")
            }
        }

        lastStatus = results.isEmpty
            ? "Nothing enabled to send."
            : results.joined(separator: " · ") + " at \(Self.timeFormatter.string(from: Date()))"
    }

    // MARK: Daily scheduling
    //
    // The menu-bar app stays resident, so a one-shot Timer to the next sendHour (then
    // rescheduled on fire) is enough for an MVP daily digest.

    private func rescheduleDaily() {
        dailyTimer?.invalidate()
        dailyTimer = nil
        guard notifyOnMac || slackEnabled else { return }
        let fireDate = Self.nextFireDate(hour: sendHour, from: Date())
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.sendNow()
                self?.rescheduleDaily()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    /// Next occurrence of `hour:00` strictly after `now`. Pure → unit-testable.
    nonisolated static func nextFireDate(hour: Int, from now: Date, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        let candidate = calendar.date(from: comps) ?? now
        return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    // MARK: Bridge to the deep-analysis tool (coach.sh)

    /// Launch the existing ai-coach deep analysis in Terminal (it needs the `claude` CLI and an
    /// interactive context, so we don't embed it). Best-effort; reports status.
    func runDeepAnalysis() {
        let candidates = [
            "\(NSHomeDirectory())/Desktop/projects/ai-coach/coach.sh",
            "../ai-coach/coach.sh",
        ]
        guard let script = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            lastStatus = "Couldn't find ai-coach/coach.sh."
            return
        }
        let appleScript = "tell application \"Terminal\" to do script \"\(script)\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", appleScript]
        do {
            try task.run()
            lastStatus = "Launched deep analysis in Terminal."
        } catch {
            lastStatus = "Couldn't launch: \(error.localizedDescription)"
        }
    }

    // MARK: Persistence & formatting

    private func persist() {
        let d = UserDefaults.standard
        d.set(slackEnabled, forKey: Keys.enabled)
        d.set(webhookURL, forKey: Keys.webhook)
        d.set(sendHour, forKey: Keys.hour)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
