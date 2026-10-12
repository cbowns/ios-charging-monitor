import SwiftUI

/// Measures how often each HID sensor actually changes, to pick a polling rate. Reads every
/// sensor at ~50 Hz for 10 s and records when each value changes; also times the powerd and
/// registry calls. Run it while charging over USB-C so the charger sensors are moving.
@MainActor
final class SensorRateProbe: ObservableObject {
    @Published private(set) var progress: Double?
    @Published private(set) var report: String?

    private static let duration: TimeInterval = 10
    private static let period: Duration = .milliseconds(20)

    func run(monitor: PowerMonitor) {
        guard progress == nil, let sensors = monitor.sensors else { return }
        let reader = monitor.reader
        let context = monitor.snapshot.map { snap in
            [snap.statusText, snap.primaryWatts.map { String(format: "%.2f W %@", $0.value, $0.label) }, snap.adapterSummary]
                .compactMap { $0 }.joined(separator: " · ")
        } ?? "no snapshot"
        progress = 0
        report = nil
        // Keep the 1 Hz poll (and its periodic rescan) out of the way.
        monitor.stop()

        Task {
            let catalog = sensors.catalog
            let powerd = Self.timePowerd(reader)

            var last = [Double?](repeating: nil, count: catalog.count)
            var changes = [[TimeInterval]](repeating: [], count: catalog.count)
            var seen = [Int](repeating: 0, count: catalog.count)
            var readTimes: [TimeInterval] = []
            let clock = ContinuousClock()
            let start = clock.now
            func elapsed(_ since: ContinuousClock.Instant) -> TimeInterval {
                let d = clock.now - since
                return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            }

            while elapsed(start) < Self.duration {
                let readStart = clock.now
                let readings = sensors.read()
                readTimes.append(elapsed(readStart))
                let t = elapsed(start)
                for r in readings where r.id < catalog.count {
                    seen[r.id] += 1
                    if let previous = last[r.id], previous != r.value { changes[r.id].append(t) }
                    last[r.id] = r.value
                }
                progress = t / Self.duration
                try? await Task.sleep(for: Self.period)
            }
            let total = elapsed(start)

            report = Self.format(catalog: catalog, changes: changes, seen: seen, last: last,
                                 readTimes: readTimes, total: total, powerd: powerd, context: context)
            Self.save(report!)
            progress = nil
            monitor.start()
        }
    }

    /// Average milliseconds per call over 20 calls each.
    private static func timePowerd(_ reader: IOKitBattery?) -> [(String, Double)] {
        guard let reader else { return [] }
        func time(_ body: () -> Void) -> Double {
            let clock = ContinuousClock()
            let d = clock.measure { for _ in 0..<20 { body() } }
            return (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 / 20
        }
        return [
            ("IOPSCopyPowerSourcesInfo", time { _ = reader.readPowerSources() }),
            ("IOPSCopyExternalPowerAdapterDetails", time { _ = reader.readAdapterDetails() }),
            ("IOPMPowerSource registry", time { _ = reader.readProperties() }),
        ]
    }

    private static func format(catalog: [HIDSensors.ServiceInfo], changes: [[TimeInterval]], seen: [Int],
                               last: [Double?], readTimes: [TimeInterval], total: TimeInterval,
                               powerd: [(String, Double)], context: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let sorted = readTimes.sorted()
        let samples = readTimes.count
        var lines = [
            "Sensor update rates · \(RecordingFormat.modelIdentifier()) · iOS \(UIDevice.current.systemVersion) · app \(info["CFBundleShortVersionString"] ?? "?")",
            Date.now.formatted(date: .abbreviated, time: .standard),
            "State: \(context)",
            String(format: "Sampled %.1f s, %d reads (%.1f Hz achieved, 50 Hz target)", total, samples, Double(samples) / total),
            String(format: "HID read of %d sensors: median %.2f ms, max %.2f ms",
                   catalog.count, (sorted.isEmpty ? 0 : sorted[sorted.count / 2]) * 1000, (sorted.last ?? 0) * 1000),
        ]
        lines += powerd.map { String(format: "%@: %.2f ms per call", $0.0, $0.1) }
        lines.append("")

        let unit = { (usage: Int) in usage == 2 ? "A" : usage == 3 ? "V" : usage == 5 ? "°C" : "?" }
        let sampleInterval = total / Double(max(samples, 1))
        var changing: [(name: String, median: Double, min: Double, count: Int, value: Double?)] = []
        var still: [String] = []
        var missing: [String] = []
        for i in catalog.indices {
            let name = "\(catalog[i].name) [\(unit(catalog[i].usage))]"
            if seen[i] == 0 { missing.append(name); continue }
            let times = changes[i]
            guard times.count >= 2 else {
                still.append(name + (times.count == 1 ? " (changed once)" : ""))
                continue
            }
            let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
            changing.append((name, intervals[intervals.count / 2], intervals.first ?? 0, times.count, last[i]))
        }
        changing.sort { $0.median < $1.median }

        lines.append("Changing (median / min interval between changes · changes in run · last value):")
        for c in changing {
            let floor = c.median <= sampleInterval * 1.5 ? "  ← at sampling rate, may be faster" : ""
            lines.append(String(format: "  %@: %.0f ms / %.0f ms · %d · %@%@",
                                c.name, c.median * 1000, c.min * 1000, c.count,
                                c.value.map { String(format: "%.4g", $0) } ?? "-", floor))
        }
        lines.append("")
        lines.append("Unchanged during the run (\(still.count)): " + still.joined(separator: ", "))
        if !missing.isEmpty { lines.append("Never readable (NaN) (\(missing.count)): " + missing.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private static func save(_ text: String) {
        let name = "sensor-rates-" + RecordingFormat.fileNameFormatter.string(from: .now) + ".txt"
        try? text.write(to: URL.documentsDirectory.appending(path: name), atomically: true, encoding: .utf8)
    }
}

struct SensorRateReportView: View {
    let report: String
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
            .navigationTitle("Sensor rates")
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
