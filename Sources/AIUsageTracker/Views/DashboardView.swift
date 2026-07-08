import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

/// Personal dashboard: KPI cards, spend-over-time chart, and per-model cost breakdown
/// from local Claude + Cursor session files.
struct DashboardView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            kpiRow
            chart
            modelTable
        }
        .padding(20)
        .frame(minWidth: 1000, minHeight: 600)
        .task {
            if viewModel.asOfDate == "—" { await viewModel.load() }
        }
    }

    // MARK: Header + range selector

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage — Local Sessions")
                    .font(.title2.weight(.semibold))
                Text("Data as of \(viewModel.asOfDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $viewModel.selectedRange) {
                ForEach(UsageViewModel.DateRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()

            Menu {
                Button("Copy to clipboard") { copyCSV() }
                Button("Save as CSV…") { saveCSV() }
            } label: {
                Label(copied ? "Copied ✓" : "Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
        }
    }

    // MARK: CSV export

    private func copyCSV() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(viewModel.rankingCSV(), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func saveCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ai-usage-\(viewModel.selectedRange.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-\(viewModel.asOfDate).csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? viewModel.rankingCSV().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: KPI cards

    private var kpiRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                KpiCard(title: "Total Spend", value: Money.string(viewModel.totalSpend), systemImage: "dollarsign.circle")
                KpiCard(title: "Claude", value: Money.string(viewModel.claudeTotal), systemImage: "brain")
                KpiCard(title: "Cursor", value: Money.string(viewModel.cursorTotal), systemImage: "cursorarrow.rays")
                KpiCard(title: "Sessions", value: "\(viewModel.totalConversations)", systemImage: "bubble.left.and.bubble.right")
            }
            Text("\(viewModel.totalMessages) API calls  ·  priced from local token logs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Spend-over-time chart (stacked by tool)

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spend over time — by tool")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Chart(viewModel.toolSeries) { point in
                BarMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Spend (USD)", point.amount)
                )
                .foregroundStyle(by: .value("Tool", point.tool))
            }
            .chartForegroundStyleScale(["Claude": Color.accentColor, "Cursor": Color.orange])
            .chartYAxis {
                AxisMarks(format: Decimal.FormatStyle.Currency(code: "USD"))
            }
            .frame(height: 200)
        }
    }

    // MARK: Model breakdown table

    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spend by model")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Table(viewModel.modelBreakdown) {
                TableColumn("Model") { row in
                    Text(Labels.model(row.model))
                }
                TableColumn("Claude") { row in
                    Text(Money.string(row.claudeCost)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("Cursor") { row in
                    Text(Money.string(row.cursorCost)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("Total") { row in
                    Text(Money.string(row.total)).monospacedDigit().fontWeight(.semibold)
                }
                .width(90)
            }
        }
    }
}
