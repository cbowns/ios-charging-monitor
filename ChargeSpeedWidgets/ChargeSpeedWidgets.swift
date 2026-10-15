import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ChargeSpeedWidgets: WidgetBundle {
    var body: some Widget {
        ChargeLiveActivity()
    }
}

/// Lock Screen and Dynamic Island view of a charging session.
struct ChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            LockScreenView(state: context.state, start: context.attributes.start)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(watts(state.watts)).font(.title2.bold().monospacedDigit())
                        Text(state.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(percent(state.percent)).font(.title2.bold().monospacedDigit())
                        Text(state.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DetailRow(state: state)
                }
            } compactLeading: {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
            } compactTrailing: {
                Text(watts(state.watts)).monospacedDigit()
            } minimal: {
                Text(state.watts.map { String(format: "%.0f", $0) } ?? "–").monospacedDigit()
            }
        }
    }
}

private struct LockScreenView: View {
    let state: ChargeActivityAttributes.ContentState
    let start: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                Text(watts(state.watts)).font(.system(size: 40, weight: .bold).monospacedDigit())
                Text(state.source).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(percent(state.percent)).font(.title2.bold().monospacedDigit())
                    Text(state.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                DetailRow(state: state)
                Spacer()
                Text(start, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding()
        .foregroundStyle(.white)
    }
}

private struct DetailRow: View {
    let state: ChargeActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Label(watts(state.batteryWatts) + " into battery", systemImage: "battery.100percent.bolt")
            if let t = state.batteryTemperatureC {
                Label(String(format: "%.1f °C", t), systemImage: "thermometer.medium")
                    .foregroundStyle(t >= 42 ? .red : t >= 38 ? .orange : .primary)
            }
        }
        .font(.caption.monospacedDigit())
    }
}

private func watts(_ w: Double?) -> String { w.map { String(format: "%.1f W", $0) } ?? "– W" }
private func percent(_ p: Int?) -> String { p.map { "\($0) %" } ?? "– %" }
