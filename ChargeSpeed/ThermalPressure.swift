import Foundation
import notify

/// The system thermal pressure level from the `com.apple.system.thermalpressurelevel` notify
/// state, readable on iOS 27 (iPhone 14 Pro). `ProcessInfo.thermalState` is a four-step summary
/// of it; this one moves first.
enum ThermalPressure {
    private static let token: Int32? = {
        var token: Int32 = 0
        return notify_register_check("com.apple.system.thermalpressurelevel", &token) == NOTIFY_STATUS_OK ? token : nil
    }()

    /// nil when the state can't be read.
    static func current() -> Int? {
        guard let token else { return nil }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return nil }
        return Int(state)
    }

    /// Level names as macOS defines them (OSThermalNotification.h); iOS appears to share them.
    static func name(_ level: Int) -> String {
        switch level {
        case 0: return "nominal"
        case 1: return "moderate"
        case 2: return "heavy"
        case 3: return "trapping"
        case 4: return "sleeping"
        default: return "level \(level)"
        }
    }
}
