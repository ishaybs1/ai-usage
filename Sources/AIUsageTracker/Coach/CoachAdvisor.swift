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
         "“Use ~/Documents/findings.pdf — don’t search for it.”"),
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

    /// Up to `limit` coaching lines for one expensive session. Prefer transcript signals so tips
    /// cite real repo/branch/prompt facts — never pad with the same generic line across sessions.
    static func coachingTips(
        for session: SessionCost,
        signals: TranscriptSignals? = nil,
        limit: Int = 3
    ) -> [String] {
        var tips: [String] = []
        let repo = signals?.repo ?? session.title.split(separator: "—").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let branch = signals?.branch
        let model = session.dominantModel.lowercased()

        // 1) Model / cost
        if let sig = signals, sig.opusAssistantShare >= 0.35, session.cost >= 5 {
            let pct = Int((sig.opusAssistantShare * 100).rounded())
            let where_ = repo.map { " in `\($0)`" } ?? ""
            tips.append("Opus was ~\(pct)% of assistant turns\(where_) (\(Money.string(session.cost))) — keep Sonnet for build/log/check loops; escalate to Opus only when root-cause reasoning stalls.")
        } else if model.contains("opus"), session.cost >= 3 {
            let where_ = repo.map { " on `\($0)`" } ?? ""
            tips.append("This\(where_) chat was mostly Opus at \(Money.string(session.cost)) — rerun routine verify/fix steps on Sonnet (~5× cheaper).")
        }

        // 2) Length / thread hygiene
        if session.messages >= 80 {
            let loc = [repo.map { "`\($0)`" }, branch.map { "`\($0)`" }].compactMap { $0 }.joined(separator: " / ")
            let place = loc.isEmpty ? "this thread" : loc
            tips.append("\(session.messages) billable turns on \(place) — checkpoint progress and open a **new** chat for the next milestone so prior history isn't re-sent every turn.")
        } else if session.messages >= 25 {
            tips.append("\(session.messages) turns already — before the next probe, paste the current hypothesis + exact command to run; don't explore with another vague ask.")
        }

        // 3) Short / weak prompts
        if let sig = signals, sig.userPromptCount >= 5, sig.shortPromptShare >= 0.25 {
            let pct = Int((sig.shortPromptShare * 100).rounded())
            let example = sig.weakPrompts.first.map { " (e.g. “\($0)”)" } ?? ""
            tips.append("\(pct)% of your prompts were ≤3 words\(example) — each still reloads the full thread; batch the next 2–3 asks into one message.")
        }

        // 4) Interrupts
        if let sig = signals, sig.interruptCount >= 3 {
            tips.append("You interrupted the agent \(sig.interruptCount)× — stop/restart loops burn turns; write one message with goal + constraints + how to verify, then let it finish.")
        }

        // 5) Tool-heavy thrash
        if let sig = signals, sig.assistantTurns > 0 {
            let toolShare = Double(sig.toolUseTurns) / Double(sig.assistantTurns)
            if toolShare >= 0.45, session.messages >= 20 {
                tips.append("Tool-use was ~\(Int((toolShare * 100).rounded()))% of assistant turns — hand exact paths/commands for the next check so it doesn't keep exploring.")
            }
        }

        // 6) Rewrite a real weak opener
        if let weak = signals?.weakPrompts.first(where: { $0.split(whereSeparator: \.isWhitespace).count <= 4 }),
           tips.count < limit {
            let context = [repo, branch].compactMap { $0 }.joined(separator: " · ")
            let prefix = context.isEmpty ? "Instead of" : "In \(context), instead of"
            tips.append("\(prefix) “\(weak)”, write: goal + files/commands + what “done” looks like — in one message.")
        } else if let sample = signals?.samplePrompts.first(where: { $0.count < 90 }),
                  tips.count < limit,
                  sample.lowercased().hasPrefix("can you") || sample.lowercased().contains("fix it") {
            tips.append("Opener “\(sample)” is underspecified — name the failing symptom, the file/command, and the success check up front.")
        }

        // 7) Title-aware fallbacks (still specific, not the old generic pad list)
        if let title = signals?.aiTitle ?? session.title.split(separator: "—").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
           tips.count < limit, title.count > 8 {
            tips.append("For “\(ClaudeSessionLabel.truncateWords(title, maxWords: 8))”: state the smallest next milestone and a verify command before asking the agent to continue.")
        }

        if session.cost >= 20, tips.count < limit {
            tips.append("At \(Money.string(session.cost)), split remaining work into scoped sessions (one milestone each) — long threads dominate spend more than model choice alone.")
        }

        // Last resorts — still vary by session numbers so they aren't identical clones.
        let lasts = [
            "Lead with the error signature + one command to reproduce before any “fix it” follow-up.",
            "Prefer one packed message (context + ask + verify) over \(max(session.messages / 10, 2))+ mini follow-ups.",
            "If the task changed mid-thread, start fresh — mixed goals inflate tokens on every later turn.",
        ]
        for t in lasts where tips.count < limit {
            if !tips.contains(t) { tips.append(t) }
        }

        // Dedup while preserving order
        var seen = Set<String>()
        let unique = tips.filter { seen.insert($0).inserted }
        return Array(unique.prefix(max(limit, 0)))
    }

    /// First coaching line (back-compat for call sites that want a single string).
    static func coaching(for session: SessionCost) -> String {
        coachingTips(for: session, limit: 1).first ?? "Lead with the error signature + one command to reproduce before any “fix it” follow-up."
    }
}
