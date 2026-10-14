import SwiftUI

/// Measures each sensor's real update rate, to tune `SensorSampler`. Runs on the sampler's
/// queue with sampling held off (about 35 s):
/// 1. reads every sensor alone a few times, to find what one read costs and whether some
///    sensors are slower to read than others;
/// 2. reads each fast sensor, plus one of each slower kind, alone in a tight loop for 3 s and
///    records when its value changes. A read takes ~1 ms, so changes are resolved to ~1 ms.
/// Run it while charging over USB-C so the charger sensors are moving.
@MainActor
final class SensorRateProbe: ObservableObject {
    @Published private(set) var progress: Double?
    @Published private(set) var report: String?

    nonisolated private static let loopDuration: TimeInterval = 3
    /// One representative of each slower group, by name prefix.
    nonisolated private static let representativePrefixes = ["PMU tdie", "Charger TQ0j", "PMU tdev", "gas gauge battery"]

    func run(monitor: PowerMonitor) {
        guard progress == nil, let sampler = monitor.sampler else { return }
        let reader = monitor.reader
        let context = monitor.snapshot.map { snap in
            [snap.statusText, snap.primaryWatts.map { String(format: "%.2f W %@", $0.value, $0.label) }, snap.adapterSummary]
                .compactMap { $0 }.joined(separator: " · ")
        } ?? "no snapshot"
        let header = "Sensor update rates (single-sensor) · \(RecordingFormat.modelIdentifier()) · iOS \(UIDevice.current.systemVersion) · app \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")"
        let tickStats = sampler.tickStats()
        progress = 0
        report = nil

        sampler.exclusive { sensors, catalog, fastIDs in
            let setProgress = { (p: Double) in DispatchQueue.main.async { self.progress = min(max(p, 0), 1) } }
            let text = Self.measure(sensors: sensors, catalog: catalog, fastIDs: fastIDs, reader: reader,
                                    header: header, context: context, tickStats: tickStats, progress: setProgress)
            Self.save(text)
            DispatchQueue.main.async {
                self.report = text
                self.progress = nil
            }
        }
    }

    nonisolated private static func measure(sensors: HIDSensors, catalog: [HIDSensors.ServiceInfo], fastIDs: [Int],
                                            reader: IOKitBattery?, header: String, context: String,
                                            tickStats: SensorSampler.TickStats,
                                            progress: (Double) -> Void) -> String {
        let clock = ContinuousClock()
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        func ms(_ v: Double) -> String { String(format: "%.2f ms", v * 1000) }
        func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        let unit = { (usage: Int) in usage == 2 ? "A" : usage == 3 ? "V" : usage == 5 ? "°C" : "?" }
        func label(_ i: Int) -> String { "\(catalog[i].name) [\(unit(catalog[i].usage))]" }

        var lines = [header, Date.now.formatted(date: .abbreviated, time: .standard), "State: \(context)",
                     String(format: "Sampler (last %d ticks at 10 Hz): median %.1f ms, max %.1f ms per tick",
                            tickStats.ticks, tickStats.medianMs, tickStats.maxMs)]

        // powerd and registry cost.
        if let reader {
            func time(_ body: () -> Void) -> Double { seconds(clock.measure { for _ in 0..<20 { body() } }) / 20 }
            lines.append("powerd: sources \(ms(time { _ = reader.readPowerSources() })) · adapter \(ms(time { _ = reader.readAdapterDetails() })) · registry \(ms(time { _ = reader.readProperties() })) per call")
        }

        // 1. Per-sensor read cost.
        var cost: [(id: Int, seconds: Double)] = []
        for i in catalog.indices {
            var samples: [Double] = []
            for _ in 0..<5 { samples.append(seconds(clock.measure { _ = sensors.read([i]) })) }
            cost.append((i, median(samples)))
        }
        let typical = median(cost.map(\.seconds))
        lines.append("")
        lines.append("Read cost, one sensor at a time (\(catalog.count) sensors): median \(ms(typical)), total \(ms(cost.reduce(0) { $0 + $1.seconds }))")
        let slowReads = cost.filter { $0.seconds > typical * 2 }.sorted { $0.seconds > $1.seconds }
        if slowReads.isEmpty {
            lines.append("  No sensor takes more than 2× the median.")
        } else {
            for c in slowReads { lines.append("  slow: \(label(c.id)) \(ms(c.seconds))") }
        }
        progress(0.05)

        // 2. Tight loop per target sensor.
        var targets = fastIDs
        for prefix in representativePrefixes {
            if let i = catalog.indices.first(where: { catalog[$0].name.hasPrefix(prefix) }), !targets.contains(i) { targets.append(i) }
        }
        lines.append("")
        lines.append("Tight loop, \(Int(loopDuration)) s per sensor. Change interval is an upper bound on the update period")
        lines.append("(a steady value can repeat across updates). Columns: reads/s · median read · changes · median / min change interval · distinct values · last")
        for (n, i) in targets.enumerated() {
            var reads = 0
            var readTimes: [Double] = []
            var changes: [Double] = []
            var last: Double?
            var distinct = Set<Double>()
            let start = clock.now
            while seconds(clock.now - start) < loopDuration {
                let t0 = clock.now
                let value = sensors.read([i]).first?.value
                readTimes.append(seconds(clock.now - t0))
                reads += 1
                guard let value else { continue }
                distinct.insert(value)
                if let last, last != value { changes.append(seconds(clock.now - start)) }
                last = value
            }
            let intervals = zip(changes.dropFirst(), changes).map { $0 - $1 }
            let changeText = intervals.isEmpty
                ? (changes.isEmpty ? "no change" : "changed once")
                : "\(ms(median(intervals))) / \(ms(intervals.min() ?? 0))"
            lines.append(String(format: "  %@: %.0f/s · %@ · %d · %@ · %d · %@",
                                label(i), Double(reads) / loopDuration, ms(median(readTimes)), changes.count,
                                changeText, distinct.count, last.map { String(format: "%.4g", $0) } ?? "NaN"))
            progress(0.05 + 0.95 * Double(n + 1) / Double(targets.count))
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func save(_ text: String) {
        let name = "sensor-rates-" + RecordingFormat.fileNameFormatter.string(from: .now) + ".txt"
        try? text.write(to: URL.documentsDirectory.appending(path: name), atomically: true, encoding: .utf8)
    }
}

struct SensorRateReportView: View {
    let report: String
    var title = "Sensor rates"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = report
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }
}
