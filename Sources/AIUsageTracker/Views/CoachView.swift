import SwiftUI

/// Cost Coach window: the top-3 cost-cutting tips, a personalized insight, and the daily
/// Slack digest settings.
struct CoachView: View {
    @ObservedObject var coach: CoachViewModel
    @ObservedObject var usage: UsageViewModel

    /// Which tips have their example expanded (by tip rank).
    @State private var expandedTips: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                expensiveSessionsSection
                tipsSection
                budgetSection
                digestSection
                Divider()
                Text("Data as of \(usage.asOfDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cost Coach 🧑‍🏫")
                .font(.title2.weight(.semibold))
            Text("Same results, fewer turns.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Today's most expensive sessions

    private var expensiveSessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today's 3 most expensive sessions")
                    .font(.headline)
                Spacer()
                Text(coach.topSessionsDay)
                    .font(.caption).foregroundStyle(.secondary)
            }

            if coach.topSessions.isEmpty {
                Text("No priced sessions yet for \(coach.topSessionsDay).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(Array(coach.topSessions.enumerated()), id: \.element.session.id) { idx, item in
                    expensiveSessionRow(rank: idx + 1, session: item.session, tips: item.advice)
                }
            }
        }
    }

    private func expensiveSessionRow(rank: Int, session: SessionCost, tips: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.tint)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Text(Money.string(session.cost))
                        .font(.body.weight(.semibold).monospacedDigit())
                }
                HStack(spacing: 6) {
                    tag(session.tool)
                    if !session.dominantModel.isEmpty { tag(Labels.model(session.dominantModel)) }
                    tag("\(session.messages) msgs")
                }
                ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                    Label(tip, systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.tint.opacity(0.14), in: Capsule())
            .foregroundStyle(.tint)
    }

    // MARK: Tips

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top 3 ways to cut cost")
                .font(.headline)

            if let insight = coach.insight {
                Label(insight, systemImage: "sparkles")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            ForEach(coach.tips) { tip in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(tip.rank)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.tint)
                        .frame(width: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(tip.title).font(.body.weight(.semibold))
                            Spacer(minLength: 0)
                            Button {
                                if expandedTips.contains(tip.rank) { expandedTips.remove(tip.rank) }
                                else { expandedTips.insert(tip.rank) }
                            } label: {
                                Image(systemName: expandedTips.contains(tip.rank) ? "minus.circle" : "plus.circle")
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .help("Show an example")
                        }
                        Text(tip.detail).font(.callout).foregroundStyle(.secondary)
                        if expandedTips.contains(tip.rank) {
                            examplePair(wrong: tip.wrong, right: tip.right)
                        }
                    }
                }
            }

            Button {
                coach.runDeepAnalysis()
            } label: {
                if coach.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Text("Analyzing…")
                } else {
                    Label("Analyze my transcripts…", systemImage: "doc.text.magnifyingglass")
                }
            }
            .disabled(coach.isAnalyzing)
            .padding(.top, 4)
            Text("3 tips per costly session from local transcript rules (no cloud / no CLI subprocess).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Compact ✗ what-went-wrong / ✓ what-to-do example, shown when a tip is expanded.
    private func examplePair(wrong: String, right: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label { Text(wrong) } icon: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            Label { Text(right) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Monthly budget

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Monthly budget")
                .font(.headline)
            HStack {
                Text("Alert me if I'm tracking over")
                Spacer()
                TextField("0", value: $usage.monthlyBudget, format: .currency(code: "USD"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
            }
            if usage.monthlyBudget > 0 {
                Text("Month-to-date \(Money.string(usage.combinedThisMonth)) · projected \(Money.string(usage.projectedMonthSpend)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Set a cap to get a menu-bar warning. 0 = off.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Daily digest

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Daily digest")
                .font(.headline)

            Toggle("Notify me on this Mac", isOn: $coach.notifyOnMac)
            Text("A local notification with today's spend and a tip — no setup, no URL.")
                .font(.caption2).foregroundStyle(.tertiary)

            Toggle("Also send to Slack", isOn: $coach.slackEnabled)
            if coach.slackEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Incoming webhook URL")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("https://hooks.slack.com/services/…", text: $coach.webhookURL)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
            }

            HStack {
                Stepper(value: $coach.sendHour, in: 0...23) {
                    Text("Send at \(String(format: "%02d:00", coach.sendHour))")
                }
                .fixedSize()
                Spacer()
                Button {
                    Task { await coach.sendNow() }
                } label: {
                    if coach.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send test now")
                    }
                }
                .disabled(!coach.canDeliver || coach.isSending)
            }

            if let status = coach.lastStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            Text("Settings stored locally on this Mac.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
