import SwiftUI
import AppKit

/// The popover shown when the menu-bar item is clicked: today / month spend, product & model
/// breakdowns, the data-date status line, and an "Open dashboard" button.
struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: UsageViewModel
    /// Provided by AppDelegate — open the dashboard / coach NSWindows.
    var onOpenDashboard: () -> Void = {}
    var onOpenCoach: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    /// " · v1.1" from the bundle when packaged; empty when run as the raw binary (no bundle).
    private static let versionSuffix: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { " · v\($0)" } ?? ""
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My AI Usage")
                .font(.headline)

            // Two large numbers: combined (all tools) today and month-to-date.
            HStack(alignment: .top, spacing: 28) {
                stat(label: "Today", value: viewModel.combinedToday)
                stat(label: "This Month", value: viewModel.combinedThisMonth)
            }

            // Day-over-day delta.
            if let delta = viewModel.dayOverDayDelta {
                let up = delta >= 0
                Label {
                    Text("\(up ? "+" : "")\(Int((delta * 100).rounded()))% vs yesterday")
                } icon: {
                    Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                }
                .font(.caption)
                .foregroundStyle(up ? .red : .green)
            }

            // Per-tool split for today.
            HStack(spacing: 6) {
                Text("Claude \(Money.string(viewModel.mySpendToday))")
                Text("·").foregroundStyle(.tertiary)
                Text("Cursor \(Money.string(viewModel.myCursorToday))")
                if viewModel.myCursorFastToday > 0 {
                    Text("(\(viewModel.myCursorFastToday) fast)").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // How to read the two numbers: when Cursor billing API is live, Claude JSONL only
            // counts external CLI on days without Cursor charges (avoids double-counting Claude Code).
            Text(viewModel.cursorUsingAPI
                 ? "Claude CLI = est. (non-Cursor days) · Cursor = actual billed"
                 : "Claude = est. (list price) · Cursor = actual billed")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // ROI: output for the spend this month.
            Label {
                if let cpc = viewModel.myCostPerCommit {
                    Text("\(viewModel.myCommitsThisMonth) commits this month · \(Money.string(cpc))/commit")
                } else {
                    Text("\(viewModel.myCommitsThisMonth) commits this month")
                }
            } icon: {
                Image(systemName: "arrow.triangle.branch")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Budget warning (amber/red) when trending over or over the monthly cap.
            if let warning = viewModel.budgetWarning {
                Label(warning, systemImage: viewModel.budgetStatus == .over ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(viewModel.budgetStatus == .over ? .red : .orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((viewModel.budgetStatus == .over ? Color.red : Color.orange).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            BreakdownBars(title: "Claude — by Product", values: viewModel.myProductBreakdown, prettify: Labels.product)
            BreakdownBars(title: "Claude — by Model", values: viewModel.myModelBreakdown, prettify: Labels.model)

            Divider()

            cursorSection

            Divider()

            // Local session data — refreshed on each open.
            Text("From local sessions · as of \(viewModel.asOfDate)\(Self.versionSuffix)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Coach teaser: today's first cost-cutting tip, with a button to the full Coach window.
            if let topTip = CoachAdvisor.tips(on: Date()).first {
                Label("Tip: \(topTip.title)", systemImage: "lightbulb")
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    onOpenCoach()
                } label: {
                    Label("Cost coach", systemImage: "lightbulb")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    onOpenDashboard()
                } label: {
                    Label("Dashboard", systemImage: "chart.bar.xaxis")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)

            // Refresh + Quit.
            HStack {
                Button {
                    Task { await viewModel.load(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Spacer()
                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 300)
        .task {
            // Load on first open if the eager startup load hasn't populated yet.
            if viewModel.asOfDate == "—" { await viewModel.load() }
        }
    }

    /// Cursor has no product/model breakdown, so we show its spend + request counts.
    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cursor")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if viewModel.cursorRecentUnavailable {
                cursorRow("Spend today", "n/a")
                cursorRow(viewModel.cursorMonthIsManual ? "This month (manual)" : "This month",
                          viewModel.cursorMonthIsManual ? Money.string(viewModel.myCursorThisMonth) : "n/a")
            } else {
                cursorRow("Spend today", Money.string(viewModel.myCursorToday))
                cursorRow("Spend this month", Money.string(viewModel.myCursorThisMonth))
                if !viewModel.myCursorModelBreakdown.isEmpty {
                    BreakdownBars(title: "Cursor — by Model", values: viewModel.myCursorModelBreakdown, prettify: Labels.model)
                }
            }
            cursorSourceNote
        }
    }

    /// Explain where Cursor numbers come from (local files no longer carry recent usage).
    @ViewBuilder private var cursorSourceNote: some View {
        if viewModel.cursorUsingAPI && viewModel.cursorApiStatus == nil {
            Label(viewModel.cursorSourceInUse == .personalToken ? "via your Cursor login" : "via Cursor Admin API",
                  systemImage: "cloud")
                .font(.caption2).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let status = viewModel.cursorApiStatus {
                    Label(status, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(3)
                }
                Button(action: onOpenSettings) {
                    Label("Recent Cursor cost isn't stored locally — connect API or enter it manually",
                          systemImage: "cloud")
                        .font(.caption2)
                }
                .buttonStyle(.link)
            }
        }
    }

    private func cursorRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption2).monospacedDigit()
        }
    }

    private func stat(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Money.string(value))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}
