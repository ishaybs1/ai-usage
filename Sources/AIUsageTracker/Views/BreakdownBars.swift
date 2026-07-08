import SwiftUI

/// A small labeled list of horizontal bars (one per breakdown key), sorted high → low and
/// scaled to the largest value. Reused by the popover for "By Product" / "By Model".
struct BreakdownBars: View {
    let title: String
    let values: [String: Double]
    /// Maps a raw key to a display label (e.g. `Labels.product`).
    var prettify: (String) -> String = { $0 }

    var body: some View {
        let entries = values.sorted { $0.value > $1.value }
        let maxValue = entries.first?.value ?? 0

        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if entries.isEmpty {
                Text("No data").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(entries, id: \.key) { key, value in
                    HStack(spacing: 8) {
                        Text(prettify(key))
                            .font(.caption2)
                            .frame(width: 92, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            Capsule()
                                .fill(.tint)
                                .frame(width: maxValue > 0 ? max(2, geo.size.width * value / maxValue) : 0)
                        }
                        .frame(height: 8)
                        Text(Money.string(value))
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }
}
