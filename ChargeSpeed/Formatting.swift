import Foundation

enum Formatting {
    /// "37.8 °C / 100.0 °F"
    static func temperature(_ celsius: Double) -> String {
        String(format: "%.1f °C / %.1f °F", celsius, celsius * 9 / 5 + 32)
    }

    /// "15.0 V × 3.00 A". `padded` left-pads the numbers with figure spaces (" 9.0 V") so
    /// stacked lines line up in a monospaced-digit font.
    static func voltsAmps(voltage_mV: Int, current_mA: Int, padded: Bool = false) -> String {
        let volts = String(format: "%.1f", Double(voltage_mV) / 1000)
        let amps = String(format: "%.2f", Double(current_mA) / 1000)
        return padded ? "\(pad(volts, 4)) V × \(pad(amps, 4)) A" : "\(volts) V × \(amps) A"
    }

    /// "45 W", or padded to two digits (phone chargers stay under 100 W).
    static func watts(_ w: Int, padded: Bool = false) -> String {
        padded ? "\(pad(String(w), 2)) W" : "\(w) W"
    }

    /// Left-pads with figure spaces (U+2007), which are digit-wide under `.monospacedDigit()`.
    private static func pad(_ text: String, _ width: Int) -> String {
        String(repeating: "\u{2007}", count: max(width - text.count, 0)) + text
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
