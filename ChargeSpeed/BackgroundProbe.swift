#if DEBUG
import UIKit

/// Spike: logs whether HID sensors, powerd and the recorder still work while the app is
/// backgrounded or locked. Temporary; remove once answered.
@MainActor
enum BackgroundProbe {
    private static var lastTick: Date?
    private static var lastState: UIApplication.State?
    private static var count = 0
    private static var lastSize: Int?

    static func log(_ snap: PowerSnapshot, recording: URL?) {
        let app = UIApplication.shared
        let state = app.applicationState
        let gap = lastTick.map { snap.date.timeIntervalSince($0) } ?? 0
        lastTick = snap.date
        count += 1
        let changed = state != lastState
        lastState = state
        guard changed || (state != .active && count % 10 == 0) else { return }

        func sensor(_ name: String) -> String {
            guard let r = snap.sensors.first(where: { $0.name == name }) else { return "\(name)=missing" }
            let spread = r.spread.map { String(format: " n=%d [%.3f…%.3f]", $0.count, $0.min, $0.max) } ?? ""
            return "\(name)=\(r.formatted)\(spread)"
        }
        let finite = snap.sensors.filter { $0.value.isFinite }.count
        let hid = "hid \(finite)/\(snap.sensors.count) finite; " + ["Charger VQ0u", "Charger IQ0u", "Charger IQ0B", "PMU VP0u", "gas gauge battery", "als"].map(sensor).joined(separator: "; ")

        let ps = snap.powerSource.map { "cap=\($0["Current Capacity"] ?? "?") state=\($0["Power Source State"] ?? "?") charging=\($0["Is Charging"] ?? "?")" } ?? "nil"
        let adapter = snap.adapterDetails.map { "\($0["Description"] ?? "?") \($0["Watts"] ?? "?") W" } ?? "nil"
        let powerd = "powerd source[\(ps)] adapter[\(adapter)] raw=\(snap.raw.count) keys"

        var file = "recording nil"
        if let url = recording {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue
            let grew = size.flatMap { s in lastSize.map { s - $0 } }
            lastSize = size
            let protection = (attrs?[.protectionKey] as? FileProtectionType)?.rawValue ?? "?"
            file = "recording size=\(size.map(String.init) ?? "unreadable") grew=\(grew.map(String.init) ?? "?") protection=\(protection)"
        }

        let stateName = ["active", "inactive", "background"][state.rawValue]
        let remaining = app.backgroundTimeRemaining
        print("BGSPIKE \(snap.date.formatted(date: .omitted, time: .standard)) state=\(stateName) protectedData=\(app.isProtectedDataAvailable) bgRemaining=\(remaining > 1e6 ? "unlimited" : String(format: "%.0f s", remaining)) gap=\(String(format: "%.2f", gap)) s")
        print("BGSPIKE   \(hid)")
        print("BGSPIKE   \(powerd)")
        print("BGSPIKE   \(file)")
    }
}
#endif
