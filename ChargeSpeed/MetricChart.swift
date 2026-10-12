import SwiftUI
import Charts

/// A value the Charging rows can chart over time.
enum ChartMetric: String, Identifiable, CaseIterable {
    case batteryWatts, batteryVoltage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .batteryWatts: return "Into battery"
        case .batteryVoltage: return "Battery voltage"
        }
    }

    var unit: String {
        switch self {
        case .batteryWatts: return "W"
        case .batteryVoltage: return "V"
        }
    }

    var format: String {
        switch self {
        case .batteryWatts: return "%.2f W"
        case .batteryVoltage: return "%.3f V"
        }
    }

    /// Watts chart from zero so charge and drain read at a glance; voltage zooms to its range.
    var includesZero: Bool { self == .batteryWatts }

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
        }
    }
}

/// Per-tick values for the charts, since launch (or since the start of a replay), capped at 12 h.
struct SeriesStore {
    struct Point {
        let date: Date
        let value: Double
        let low: Double
        let high: Double
    }

    private static let limit = 12 * 3600
    private(set) var points: [ChartMetric: [Point]] = [:]

    mutating func append(_ snap: PowerSnapshot) {
        for metric in ChartMetric.allCases {
            guard let p = metric.point(snap) else { continue }
            points[metric, default: []].append(p)
            if points[metric]!.count > Self.limit + 600 { points[metric]!.removeFirst(600) }
        }
    }
}

struct MetricChartView: View {
    @ObservedObject var monitor: PowerMonitor
    let metric: ChartMetric
    @Environment(\.dismiss) private var dismiss

    enum Span: Double, CaseIterable, Identifiable {
        case twoMinutes = 120, tenMinutes = 600, hour = 3600, all = 0
        var id: Double { rawValue }
        var label: String {
            switch self {
            case .twoMinutes: return "2m"
            case .tenMinutes: return "10m"
            case .hour: return "1h"
            case .all: return "All"
            }
        }
    }

    @State private var span: Span = .tenMinutes
    @State private var scrollX: Date

    /// The scroll position has to start at the latest data; setting it in onAppear is ignored.
    init(monitor: PowerMonitor, metric: ChartMetric) {
        self.monitor = monitor
        self.metric = metric
        let last = monitor.series.points[metric]?.last?.date ?? .now
        let length = Span.tenMinutes.rawValue
        _scrollX = State(initialValue: last.addingTimeInterval(Self.trailingPad(length) - length))
    }
    @State private var followLive = true
    @State private var selected: Date?

    /// Kinds worth marking on a battery chart; brightness and appearance would be clutter.
    private static let markedEvents: Set<ChargeEvent.Kind> = [.plugIn, .unplug, .adapter, .profile, .status, .thermal, .batteryTemp]
    /// Swift Charts draws every mark in a scrollable chart, so long series are bucketed.
    private static let maxPoints = 3000

    var body: some View {
        let raw = monitor.series.points[metric] ?? []
        let points = Self.downsample(raw)
        let first = raw.first?.date ?? .now
        let last = raw.last?.date ?? .now
        let length = span == .all ? max(last.timeIntervalSince(first), 60) : span.rawValue
        // The x axis runs a little past the newest point; a scrollable chart's content ends at
        // its domain, and a time label centred on a tick near the end was cropped.
        let end = last.addingTimeInterval(Self.trailingPad(length))
        let events = monitor.events.filter { Self.markedEvents.contains($0.kind) && $0.date >= first && $0.date <= last }

        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                header(raw)
                Picker("Span", selection: $span) {
                    ForEach(Span.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if points.count < 2 {
                    ContentUnavailableView("Not enough data yet", systemImage: "chart.xyaxis.line",
                                           description: Text("Values are kept from app launch, one per second."))
                } else {
                    chart(points, events: events, first: first, end: end, length: length)
                }
                if !followLive {
                    Button {
                        followLive = true
                        scrollX = end.addingTimeInterval(-length)
                    } label: {
                        Label("Now", systemImage: "arrow.right.to.line")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onChange(of: span) { _, _ in
                followLive = true
                scrollX = end.addingTimeInterval(-length)
            }
            .onChange(of: last) { _, _ in
                if followLive { scrollX = end.addingTimeInterval(-length) }
            }
            .onChange(of: scrollX) { _, x in
                // Scrolled back by hand: stop following until "Now".
                if x.addingTimeInterval(length) < end.addingTimeInterval(-3) { followLive = false }
            }
        }
    }

    private func header(_ raw: [SeriesStore.Point]) -> some View {
        let shown = selected.flatMap { s in raw.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } } ?? raw.last
        return VStack(alignment: .leading, spacing: 2) {
            Text(shown.map { String(format: metric.format, $0.value) } ?? "—")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(shown.map { ($0.date.formatted(date: .omitted, time: .standard)) + (selected == nil ? " · latest" : "") } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lo = raw.map(\.value).min(), let hi = raw.map(\.value).max() {
                Text("Since \(raw.first!.date.formatted(date: .omitted, time: .shortened)): "
                     + String(format: metric.format, lo) + " – " + String(format: metric.format, hi))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func chart(_ points: [SeriesStore.Point], events: [ChargeEvent], first: Date, end: Date, length: TimeInterval) -> some View {
        // At least one full span wide, so a short history sits at the right (live) edge.
        let domainStart = min(first, end.addingTimeInterval(-length))
        let chart = Chart {
            ForEach(points, id: \.date) { p in
                if p.high > p.low {
                    AreaMark(x: .value("Time", p.date), yStart: .value("Low", p.low), yEnd: .value("High", p.high))
                        .foregroundStyle(Color.accentColor.opacity(0.2))
                }
                LineMark(x: .value("Time", p.date), y: .value(metric.unit, p.value))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.linear)
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
        .chartXScale(domain: domainStart...end)
        .chartYScale(domain: .automatic(includesZero: metric.includesZero))
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: Self.ticks(from: domainStart, to: end, length: length)) { value in
                AxisGridLine()
                // Centred under the tick; date labels otherwise start at it and run off the end.
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text((span == .twoMinutes ? Self.secondsFormatter : Self.minutesFormatter).string(from: date))
                    }
                }
            }
        }
        .frame(height: 320)

        if span == .all {
            chart
        } else {
            chart
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: length)
                .chartScrollPosition(x: $scrollX)
        }
    }

    /// Tick marks on round times, about four per visible span. Ticks near either end of the
    /// domain are skipped: a scrollable chart clips at its domain, which cropped those labels.
    private static func ticks(from start: Date, to end: Date, length: TimeInterval) -> [Date] {
        let steps: [TimeInterval] = [15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600]
        let step = steps.first { $0 >= length / 4 } ?? 21600
        let margin = length * 0.12
        var t = (start.timeIntervalSinceReferenceDate / step).rounded(.up) * step
        var ticks: [Date] = []
        while t <= end.timeIntervalSinceReferenceDate - margin {
            if t >= start.timeIntervalSinceReferenceDate + margin / 2 { ticks.append(Date(timeIntervalSinceReferenceDate: t)) }
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

    /// Room past the newest point: 10% of the visible span.
    private static func trailingPad(_ length: TimeInterval) -> TimeInterval { length * 0.1 }

    /// Buckets to at most `maxPoints`: mean of values, min of lows, max of highs.
    private static func downsample(_ raw: [SeriesStore.Point]) -> [SeriesStore.Point] {
        guard raw.count > maxPoints else { return raw }
        let size = Int((Double(raw.count) / Double(maxPoints)).rounded(.up))
        return stride(from: 0, to: raw.count, by: size).map { start in
            let bucket = raw[start..<min(start + size, raw.count)]
            return .init(date: bucket[bucket.startIndex].date,
                         value: bucket.reduce(0) { $0 + $1.value } / Double(bucket.count),
                         low: bucket.map(\.low).min()!,
                         high: bucket.map(\.high).max()!)
        }
    }
}
