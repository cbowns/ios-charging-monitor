import Foundation

/// Per-model facts the sensors can't tell us. Unknown models get the iPhone 17 Pro Max values.
struct DeviceProfile {
    let model: String
    let name: String
    /// Usable battery energy, for converting %/h into watts.
    let batteryWattHours: Double
    /// HID sensors that read the battery voltage, in order of preference.
    let batteryVoltageSensors: [String]

    static func forModel(_ model: String?) -> DeviceProfile {
        switch model {
        case "iPhone15,2":
            // 3200 mAh / 12.38 Wh. `Charger VQ0l` reads a steady ~3.25 V here (two distinct
            // values in a 3 s tight loop), so it isn't the battery; `PMU VP0u` tracks it.
            return DeviceProfile(model: "iPhone15,2", name: "iPhone 14 Pro", batteryWattHours: 12.38,
                                 batteryVoltageSensors: ["PMU VP0u", "Charger VQ0l"])
        case "iPhone18,2":
            // 5088 mAh × ~3.87 V nominal.
            return DeviceProfile(model: "iPhone18,2", name: "iPhone 17 Pro Max", batteryWattHours: 19.7,
                                 batteryVoltageSensors: ["Charger VQ0l", "PMU VP0u"])
        default:
            return DeviceProfile(model: model ?? "?", name: "\(model ?? "unknown") (17 Pro Max values)",
                                 batteryWattHours: 19.7, batteryVoltageSensors: ["Charger VQ0l", "PMU VP0u"])
        }
    }

    static let current = forModel(RecordingFormat.modelIdentifier())
}
