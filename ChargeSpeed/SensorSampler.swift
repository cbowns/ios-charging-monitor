import Foundation

/// Reads the HID sensors on a background queue so the ~1.1 ms-per-sensor cost never blocks
/// the UI. The few sensors behind the headline and battery watts are read every 100 ms and
/// averaged; the rest are read round-robin, a slice per tick, so each refreshes about once a
/// second without ever doing a full ~40–80 ms read in one go. The 1 Hz monitor calls
/// `take()` to collect each window.
final class SensorSampler: @unchecked Sendable {
    /// Charger input, battery, and wireless rail; they update faster than 15 Hz.
    static let fastNames: Set<String> = [
        "Charger VQ0u", "Charger IQ0u", "Charger IQ0B", "Charger VQ0l", "PMU VP0u", "Charger VQ1u",
    ]
    static let tickInterval: TimeInterval = 0.1
    private static let ticksPerSlowCycle = 10
    private static let rescanInterval: TimeInterval = 30

    struct Window {
        let catalog: [HIDSensors.ServiceInfo]
        let readings: [HIDSensors.Reading]
    }

    private let queue = DispatchQueue(label: "com.gregwilson.chargespeed.sensors", qos: .userInitiated)

    // Queue-confined.
    private let sensors: HIDSensors
    private var timer: DispatchSourceTimer?
    private var fastIDs: [Int] = []
    private var slowIDs: [Int] = []
    private var slowCursor = 0
    private var lastRescan = Date.distantPast
    /// Only read off the queue in `start()` before the first sync; set on the queue.
    private var primed = false

    // Shared with `take()`, guarded by `lock`.
    private let lock = NSLock()
    private var catalog: [HIDSensors.ServiceInfo] = []
    private var accumulators: [Int: Accumulator] = [:]
    private var lastFast: [Int: HIDSensors.Reading] = [:]
    private var latestSlow: [Int: HIDSensors.Reading] = [:]

    private struct Accumulator {
        let template: HIDSensors.Reading
        var sum = 0.0
        var min = Double.infinity
        var max = -Double.infinity
        var count = 0
    }

    init(sensors: HIDSensors) {
        self.sensors = sensors
    }

    /// Starts sampling. The very first call reads every sensor synchronously (one-time
    /// ~40–80 ms) so the first window isn't empty; later calls just schedule the timer.
    func start() {
        let setup = { [self] in
            guard timer == nil else { return }
            if !primed {
                primed = true
                rescan()
                let all = sensors.read()
                lock.withLock {
                    for r in all {
                        if fastIDs.contains(r.id) { lastFast[r.id] = r } else { latestSlow[r.id] = r }
                    }
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
        if primed { queue.async(execute: setup) } else { queue.sync(execute: setup) }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Everything since the last call: fast sensors as the window's mean (with min/max), the
    /// rest as their latest value.
    func take() -> Window {
        lock.withLock {
            var readings = Array(latestSlow.values)
            for (id, acc) in accumulators where acc.count > 0 {
                var r = HIDSensors.Reading(id: id, name: acc.template.name, usage: acc.template.usage,
                                           value: acc.sum / Double(acc.count))
                r.spread = .init(min: acc.min, max: acc.max, count: acc.count)
                lastFast[id] = r
            }
            accumulators.removeAll(keepingCapacity: true)
            readings += lastFast.values
            return Window(catalog: catalog, readings: readings.sorted { $0.id < $1.id })
        }
    }

    private func tick() {
        let started = Date()
        if started.timeIntervalSince(lastRescan) >= Self.rescanInterval { rescan() }

        let fast = sensors.read(fastIDs)
        let sliceSize = (slowIDs.count + Self.ticksPerSlowCycle - 1) / Self.ticksPerSlowCycle
        var slice: [Int] = []
        if !slowIDs.isEmpty {
            for _ in 0..<sliceSize {
                slice.append(slowIDs[slowCursor % slowIDs.count])
                slowCursor = (slowCursor + 1) % slowIDs.count
            }
        }
        let slow = sensors.read(slice)

        lock.withLock {
            for r in fast {
                var acc = accumulators[r.id] ?? Accumulator(template: r)
                acc.sum += r.value
                acc.min = min(acc.min, r.value)
                acc.max = max(acc.max, r.value)
                acc.count += 1
                accumulators[r.id] = acc
            }
            for r in slow { latestSlow[r.id] = r }
        }
    }

    /// Re-enumerates services. If the catalog changed, ids are no longer comparable, so all
    /// buffered readings are dropped.
    private func rescan() {
        lastRescan = Date()
        sensors.rescan()
        let newCatalog = sensors.catalog
        let changed = lock.withLock { newCatalog != catalog }
        guard changed || (fastIDs.isEmpty && slowIDs.isEmpty) else { return }
        fastIDs = newCatalog.indices.filter { Self.fastNames.contains(newCatalog[$0].name) }
        slowIDs = newCatalog.indices.filter { !Self.fastNames.contains(newCatalog[$0].name) }
        slowCursor = 0
        lock.withLock {
            catalog = newCatalog
            accumulators.removeAll()
            lastFast.removeAll()
            latestSlow.removeAll()
        }
    }
}
