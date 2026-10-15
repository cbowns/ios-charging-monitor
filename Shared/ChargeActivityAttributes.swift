import ActivityKit
import Foundation

/// The charging Live Activity, shared by the app (which starts and updates it) and the
/// widget extension (which draws it).
struct ChargeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Headline watts: charger input (USB-C), or into-battery watts on wireless.
        var watts: Double?
        /// "USB-C", "MagSafe", "wireless" or "battery".
        var source: String
        /// Power into the battery, in watts.
        var batteryWatts: Double?
        var percent: Int?
        var batteryTemperatureC: Double?
        /// "Charging", "On hold", "Charged".
        var status: String
    }

    /// When the phone was plugged in.
    var start: Date
}
