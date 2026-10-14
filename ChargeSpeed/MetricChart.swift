import SwiftUI
import Charts

/// A value the Charging and Thermals rows can chart over time.
enum ChartMetric: String, Identifiable, CaseIterable {
    case batteryWatts, batteryVoltage, batteryTemp, socTemp, ambientLux

    var id: String { rawValue }

    var title: String {
        switch self {
        case .batteryWatts: return "Into battery"
        case .batteryVoltage: return "Battery voltage"
        case .batteryTemp: return "Battery temperature"
        case .socTemp: return "SoC (hottest die)"
        case .ambientLux: return "Ambient light"
        }
    }

    var unit: String {
        switch self {
        case .batteryWatts: return "W"
        case .batteryVoltage: return "V"
        case .batteryTemp, .socTemp: return "°C"
        case .ambientLux: return "lux"
        }
    }

    var format: String {
        switch self {
        case .batteryWatts: return "%.2f W"
        case .batteryVoltage: return "%.3f V"
        case .batteryTemp, .socTemp: return "%.1f °C"
        case .ambientLux: return "%.0f lux"
        }
    }

    /// Watts chart from zero so charge and drain read at a glance; the rest zoom to their range.
    var includesZero: Bool { self == .batteryWatts }

    /// Lux spans 1 (dark) to ~100,000 (direct sun), so it's plotted on a log scale.
    var logScale: Bool { self == .ambientLux }

    /// The smallest y range to show, so sensor noise (0.04 °C, a few mV) doesn't fill the chart.
    var minimumYSpan: Double {
        switch self {
        case .batteryWatts: return 1
        case .batteryVoltage: return 0.05
        case .batteryTemp, .socTemp: return 2
        case .ambientLux: return 0
        }
    }

    /// The value with its low/high over the sampling window when the sensors were fast-sampled.
    func point(_ snap: PowerSnapshot) -> SeriesStore.Point? {
        switch self {
        case .batteryWatts:
            guard let w = snap.batteryWatts else { return nil }
            var lo = w, hi = w
            if snap.rawBatteryWatts == nil, let i = snap.sensorBatteryCurrentReading?.spread, let v = snap.sensorBatteryVoltage {
                lo = i.min * v
                hi = i.max * v
            }
            return .init(date: snap.date, value: w, low: lo, high: hi)
        case .batteryVoltage:
            guard let v = snap.batteryVoltage else { return nil }
            let spread = snap.voltage_mV == nil ? snap.sensorBatteryVoltageReading?.spread : nil
            return .init(date: snap.date, value: v, low: spread?.min ?? v, high: spread?.max ?? v)
        case .batteryTemp:
            return snap.batteryTemperatureC.map { .init(date: snap.date, value: $0, low: $0, high: $0) }
        case .socTemp:
            return snap.socMaxTemperatureC.map { .init(date: snap.date, value: $0, low: $0, high: $0) }
        case .ambientLux:
            // Log scale can't show 0; darkness reads as 1 lux.
            return snap.ambientLux.map { max($0, 1) }.map { .init(date: snap.date, value: $0, low: $0, high: $0) }
        }
    }
}

/// Per-tick values for the charts: the last 15 minutes (the longest span), since launch or
/// since the start of a replay. Longer history lives in the recordings.
struct SeriesStore {
    struct Point {
        let date: Date
        let value: Double
        let low: Double
        let high: Double
    }

    static let keep: TimeInterval = 15 * 60
    private(set) var points: [ChartMetric: [Point]] = [:]

    mutating func append(_ snap: PowerSnapshot) {
        let cutoff = snap.date.addingTimeInterval(-Self.keep - 60)
        for metric in ChartMetric.allCases {
            guard let p = metric.point(snap) else { continue }
            points[metric, default: []].append(p)
            // Trim a minute at a time rather than every tick.
            if let first = points[metric]?.first, first.date < cutoff {
                points[metric]!.removeAll { $0.date < snap.date.addingTimeInterval(-Self.keep) }
            }
        }
    }
}

/// The last 2, 5 or 15 minutes of one metric. The window is fixed to the newest data and
/// doesn't scroll: a scrollable chart re-rendered every mark on each scroll frame and was choppy.
struct MetricChartView: View {
    @ObservedObject var monitor: PowerMonitor
    let metric: ChartMetric
    @Environment(\.dismiss) private var dismiss

    enum Span: Double, CaseIterable, Identifiable {
        case two = 120, five = 300, fifteen = 900
        var id: Double { rawValue }
        var label: String { "\(Int(rawValue / 60))m" }
    }

    @State private var span: Span = .five
    @State private var selected: Date?

    /// Kinds worth marking on these charts; brightness and appearance would be clutter.
    private static let markedEvents: Set<ChargeEvent.Kind> = [.plugIn, .unplug, .adapter, .profile, .status, .thermal, .batteryTemp, .sun]

    var body: some View {
        let all = monitor.series.points[metric] ?? []
        let last = all.last?.date ?? .now
        let start = last.addingTimeInterval(-span.rawValue)
        let points = all.filter { $0.date >= start }
        let end = last.addingTimeInterval(span.rawValue * 0.05)
        let events = monitor.events.filter { Self.markedEvents.contains($0.kind) && $0.date >= start && $0.date <= last }

        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                header(points)
                Picker("Span", selection: $span) {
                    ForEach(Span.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if points.count < 2 {
                    ContentUnavailableView("Not enough data yet", systemImage: "chart.xyaxis.line",
                                           description: Text("Values are kept from app launch, one per second."))
                } else {
                    MetricChartPlot(metric: metric, points: points, events: events, start: start, end: end,
                                    showSeconds: span == .two, selected: $selected)
                        .frame(height: 320)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func header(_ points: [SeriesStore.Point]) -> some View {
        let shown = selected.flatMap { s in points.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } } ?? points.last
        return VStack(alignment: .leading, spacing: 2) {
            Text(shown.map { String(format: metric.format, $0.value) } ?? "—")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(shown.map { ($0.date.formatted(date: .omitted, time: .standard)) + (selected == nil ? " · latest" : "") } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lo = points.map(\.value).min(), let hi = points.map(\.value).max() {
                Text("Last \(span.label): " + String(format: metric.format, lo) + " – " + String(format: metric.format, hi))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The plot alone, so the header and picker don't rebuild it.
private struct MetricChartPlot: View {
    let metric: ChartMetric
    let points: [SeriesStore.Point]
    let events: [ChargeEvent]
    let start: Date
    let end: Date
    let showSeconds: Bool
    @Binding var selected: Date?

    var body: some View {
        // One band for the whole series when any sample has a spread; per-point conditionals
        // break the area into disjoint pieces.
        let hasBand = points.contains { $0.high > $0.low }
        Chart {
            if hasBand {
                ForEach(points, id: \.date) { p in
                    AreaMark(x: .value("Time", p.date), yStart: .value("Low", p.low), yEnd: .value("High", p.high))
                        .foregroundStyle(Color.accentColor.opacity(0.2))
                }
            }
            ForEach(points, id: \.date) { p in
                LineMark(x: .value("Time", p.date), y: .value(metric.unit, p.value))
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(events) { e in
                RuleMark(x: .value("Event", e.date))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .top, spacing: 0) {
                        Image(systemName: e.kind.symbol).font(.caption2).foregroundStyle(.secondary)
                            .padding(2)
                            .background(.background, in: Circle())
                    }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected))
                    .foregroundStyle(Color.primary.opacity(0.4))
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: yDomain, type: metric.logScale ? .log : .linear)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: Self.ticks(from: start, to: end)) { value in
                AxisGridLine()
                // Centred under the tick; date labels otherwise start at it and run off the end.
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text((showSeconds ? Self.secondsFormatter : Self.minutesFormatter).string(from: date))
                    }
                }
            }
        }
    }

    /// The data's range (plus zero for watts), widened to `minimumYSpan` around its middle.
    private var yDomain: ClosedRange<Double> {
        if metric.logScale {
            // At least 1–1,000 so a dim room doesn't fill the chart; then whole decades around the data.
            let lo = max(1, points.map(\.low).min() ?? 1)
            let hi = max(1000, points.map(\.high).max() ?? 1000)
            return pow(10, floor(log10(lo)))...pow(10, ceil(log10(hi)))
        }
        var lo = points.map(\.low).min() ?? 0
        var hi = points.map(\.high).max() ?? 0
        if metric.includesZero { lo = min(lo, 0); hi = max(hi, 0) }
        if hi - lo < metric.minimumYSpan {
            let mid = (lo + hi) / 2
            lo = metric.includesZero && lo >= 0 ? 0 : mid - metric.minimumYSpan / 2
            hi = lo + metric.minimumYSpan
        }
        return lo...hi
    }

    /// Ticks on round times, about four across, skipping any too close to either edge for a
    /// centred label to fit.
    private static func ticks(from start: Date, to end: Date) -> [Date] {
        let length = end.timeIntervalSince(start)
        let steps: [TimeInterval] = [15, 30, 60, 120, 300, 600]
        let step = steps.first { $0 >= length / 4 } ?? 600
        let margin = length * 0.1
        var t = (start.timeIntervalSinceReferenceDate / step).rounded(.up) * step
        var ticks: [Date] = []
        while t <= end.timeIntervalSinceReferenceDate - margin {
            if t >= start.timeIntervalSinceReferenceDate + margin { ticks.append(Date(timeIntervalSinceReferenceDate: t)) }
            t += step
        }
        return ticks
    }

    /// "4:09:30" and "4:09": no AM/PM, which doesn't fit four labels across.
    private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmmss")
        f.dateFormat = f.dateFormat.replacingOccurrences(of: " a", with: "").replacingOccurrences(of: "a", with: "")
        return f
    }()
    private static let minutesFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        f.dateFormat = f.dateFormat.replacingOccurrences(of: " a", with: "").replacingOccurrences(of: "a", with: "")
        return f
    }()
}
