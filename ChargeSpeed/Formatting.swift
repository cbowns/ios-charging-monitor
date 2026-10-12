import Foundation

enum Formatting {
    /// "37.8 °C / 100.0 °F"
    static func temperature(_ celsius: Double) -> String {
        String(format: "%.1f °C / %.1f °F", celsius, celsius * 9 / 5 + 32)
    }

    /// "15.0 V × 3.00 A"
    static func voltsAmps(voltage_mV: Int, current_mA: Int) -> String {
        String(format: "%.1f V × %.2f A", Double(voltage_mV) / 1000, Double(current_mA) / 1000)
    }
}

extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
