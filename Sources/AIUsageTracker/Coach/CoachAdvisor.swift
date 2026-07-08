import Foundation

// MARK: - Cost coaching
//
// Three high-leverage habits plus one data-driven insight from the user's own spend.
// All rule-based — no API call.

/// One piece of cost-cutting advice. `wrong`/`right` are short examples shown when expanded.
struct CoachTip: Identifiable, Equatable {
    let rank: Int
    let title: String
    let detail: String
    let wrong: String
    let right: String
    var id: Int { rank }
}

enum CoachAdvisor {
    /// Pool of short cost-cutting habits. Each day the app shows a rotating slice of 3 (see
    /// `tips(on:)`) so the advice stays fresh instead of repeating the same three forever.
    // The `wrong` examples are real openers pulled from this user's own Cursor sessions.
    static let tipPool: [(title: String, detail: String, wrong: String, right: String)] = [
        ("Say the goal up front", "Name your setup and what “done” means in the first message.",
         "You sent “but it runs on Jenkins” only after the agent had started building.",
         "“This runs on Jenkins — target that from the first step.”"),
        ("Batch your questions", "Ask for everything in one probe, not many back-and-forth commands.",
         "Opening a pipeline run link, then asking for its logs, then the failing step — one message each.",
         "“Pull run #331, its logs, and the failing step in one go.”"),
        ("Ask for the answer, not yes/no", "A yes/no reply costs an extra turn — ask for the outcome directly.",
         "“…release/331 … can you look into it?” — vague, so it explores before helping.",
         "“Why did release #331 fail on master, and how do I fix it?”"),
        ("Use Sonnet for routine work", "Reserve Opus for hard reasoning; Sonnet is ~5× cheaper for edits and Q&A.",
         "Running Opus for “change commit message and branch to feature/rtfs-4025”.",
         "Sonnet for chores like renames; Opus only for hard debugging."),
        ("Hand over paths and flags", "Give exact file paths and commands so the agent doesn’t reverse-engineer them.",
         "Letting it hunt for the findings PDF instead of giving the path.",
         "“Use /Users/ishaybs/Desktop/RT-Scalability-FINDINGS.pdf.”"),
        ("Say how to verify", "State the success check up front so the agent stops when it’s actually done.",
         "“update me it succeeded” with no defined check — so it can’t confirm.",
         "“Confirm the deploy by checking the feature-flag value flipped.”"),
        ("Start fresh for new tasks", "Long threads re-send all history every turn — open a new chat for unrelated work.",
         "Jumping from the MFE pipeline to a billing-doc task in the same long thread.",
         "New chat for the billing doc — none of the pipeline history re-sent."),
        ("Give context, not one word", "A bare word makes the agent reconstruct state — say what you actually want.",
         "Sending just “status” when a run failed.",
         "“The release run failed at the publish step — here’s the log; what broke?”"),
        ("Name constraints early", "List every target/limit in the first message, before it plans around the wrong one.",
         "Adding “also run on ../f8n nightly” after the plan was already made.",
         "“Run the test on the repo and ../f8n, both in nightly.”"),
    ]

    /// The 3 tips to show for `date`'s LOCAL day — a deterministic rotating slice of `tipPool`.
    /// Same day → same tips (stable across refreshes); consecutive days → a different slice.
    static func tips(on date: Date = Date(), calendar: Calendar = .analytics) -> [CoachTip] {
        let n = tipPool.count
        guard n > 0 else { return [] }
        let dayNumber = Int((calendar.startOfDay(for: date).timeIntervalSince1970 / 86_400).rounded(.down))
        let offset = ((dayNumber * 3) % n + n) % n   // step by 3/day; +n handles negative epochs
        return (0..<min(3, n)).map { i in
            let base = tipPool[(offset + i) % n]
            return CoachTip(rank: i + 1, title: base.title, detail: base.detail,
                            wrong: base.wrong, right: base.right)
        }
    }

    /// One observation from the user's own spend, or nil if no strong signal.
    static func insight(productBreakdown: [String: Double], modelBreakdown: [String: Double], today: Double) -> String? {
        guard today > 0 else { return nil }

        let modelTotal = modelBreakdown.values.reduce(0, +)
        if modelTotal > 0 {
            let opus = modelBreakdown.filter { $0.key.contains("opus") }.values.reduce(0, +)
            let opusShare = opus / modelTotal
            if opusShare >= 0.7 {
                return "Opus is \(Int((opusShare * 100).rounded()))% of today. Use Sonnet for routine work to cut it."
            }
        }
        if let top = productBreakdown.max(by: { $0.value < $1.value }), top.value > 0 {
            let share = top.value / max(today, 0.01)
            return "\(Labels.product(top.key)) is \(Int((share * 100).rounded()))% of today — focus there."
        }
        return nil
    }

    /// A short coaching line for one expensive session.
    static func coaching(for session: SessionCost) -> String {
        let model = session.dominantModel.lowercased()
        if model.contains("opus") {
            return "Mostly Opus — use Sonnet for edits and Q&A (~5× cheaper)."
        }
        if session.messages >= 40 {
            return "Long session (\(session.messages) turns) — batch discovery and state the goal up front."
        }
        if session.messages >= 15 {
            return "A few back-and-forths — front-load the facts to cut follow-ups."
        }
        return "Say the goal and setup up front."
    }
}
