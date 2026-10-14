import Foundation

/// Per-tick state that isn't part of the power sources: iOS's thermal verdict, the display,
/// and whether the app is in the foreground.
struct Ambient: Equatable {
    /// `ProcessInfo.ThermalState.rawValue`.
    var thermalState: Int
    /// Screen brightness, 0…1.
    var brightness: Double?
    var isDark: Bool?
    /// `UIApplication.State.rawValue`: 0 active, 1 inactive, 2 background.
    var appState: Int?
    /// `ThermalPressure` level: 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping.
    var thermalPressure: Int?

    var thermal: ProcessInfo.ThermalState { ProcessInfo.ThermalState(rawValue: thermalState) ?? .nominal }
}

/// Something worth marking on a timeline: plug-in, a new charging profile, a thermal change.
struct ChargeEvent: Identifiable {
    enum Kind: String, CaseIterable {
        case plugIn, unplug, adapter, profile, status, thermal, batteryTemp, brightness, appearance

        var symbol: String {
            switch self {
            case .plugIn: return "bolt.fill"
            case .unplug: return "bolt.slash.fill"
            case .adapter: return "cable.connector"
            case .profile: return "slider.horizontal.3"
            case .status: return "battery.100percent.bolt"
            case .thermal, .batteryTemp: return "thermometer.high"
            case .brightness: return "sun.max"
            case .appearance: return "circle.lefthalf.filled"
            }
        }
    }

    let id = UUID()
    let date: Date
    let kind: Kind
    let detail: String
}

/// Turns a stream of snapshots into events by comparing each tick with the last. The first
/// tick only sets baselines. Noisy values (charge status around plug-in, brightness while a
/// slider moves) must hold for a few seconds before they count.
struct EventDetector {
    static let batteryWarmC = 38.0
    static let batteryHotC = 42.0
    private static let tempHysteresis = 0.3
    private static let settle: TimeInterval = 5
    private static let brightnessStep = 0.1

    private var started = false
    private var pluggedIn = false
    private var adapterIdentity: String?
    private var profile: String?
    /// `profile` padded for display, so "from" and "to" stack into columns.
    private var profileText: String?
    private var status = ""
    private var plugChangedAt = Date.distantPast
    /// A plug-in waits `settle` before it's logged: iOS first reports a generic "usb charger"
    /// and switches to the real adapter a second or two later.
    private var pendingPlugIn: Date?
    private var pendingStatus: (text: String, since: Date)?
    private var thermalState = 0
    private var thermalPressure: Int?
    private var tempBand = 0
    private var brightness: Double?
    private var brightnessMovedAt: Date?
    private var isDark: Bool?

    mutating func detect(_ snap: PowerSnapshot, _ ambient: Ambient) -> [ChargeEvent] {
        let now = snap.date
        var events: [ChargeEvent] = []
        func emit(_ kind: ChargeEvent.Kind, _ detail: String, at date: Date? = nil) {
            events.append(ChargeEvent(date: date ?? now, kind: kind, detail: detail))
        }

        guard started else {
            started = true
            pluggedIn = snap.externalConnected
            adapterIdentity = snap.externalConnected ? snap.adapterIdentity : nil
            profile = snap.externalConnected ? snap.adapterProfileDescription : nil
            profileText = snap.externalConnected ? snap.adapterProfileDescription(padded: true) : nil
            status = snap.statusText
            thermalState = ambient.thermalState
            thermalPressure = ambient.thermalPressure
            tempBand = snap.batteryTemperatureC.map(Self.band) ?? 0
            brightness = ambient.brightness
            isDark = ambient.isDark
            return []
        }

        // Plug and adapter. Adapter details can arrive a tick or two after the plug flips,
        // and can briefly vanish, so nil never replaces a known adapter or profile.
        func emitPlugIn(at date: Date) {
            let kind = snap.isWirelessInput ? (snap.isMagSafe ? "MagSafe" : "Wireless") : "Plugged in"
            emit(.plugIn, [kind, snap.adapterName ?? snap.adapterDescription].compactMap { $0 }.joined(separator: " · "), at: date)
            pendingPlugIn = nil
        }
        if snap.externalConnected != pluggedIn {
            pluggedIn = snap.externalConnected
            if pluggedIn {
                pendingPlugIn = now
            } else {
                if let pending = pendingPlugIn { emitPlugIn(at: pending) }
                emit(.unplug, "Unplugged")
                adapterIdentity = nil
                profile = nil
                profileText = nil
            }
            plugChangedAt = now
        }
        if pluggedIn {
            if let id = snap.adapterIdentity, id != adapterIdentity {
                adapterIdentity = id
                // While the plug-in is settling, the adapter it ends on goes in that event.
                if pendingPlugIn == nil {
                    emit(.adapter, snap.adapterName ?? snap.adapterDescription ?? "Adapter")
                }
            }
            if let pending = pendingPlugIn, now.timeIntervalSince(pending) >= Self.settle {
                emitPlugIn(at: pending)
            }
            if let p = snap.adapterProfileDescription, p != profile,
               let text = snap.adapterProfileDescription(padded: true) {
                // Two lines, "from →" over "to", so successive changes read as columns.
                emit(.profile, profileText.map { "\($0) →\n\(text)" } ?? text)
                profile = p
                profileText = text
            }
        }

        // Charge status, debounced. Right after a plug change the status is still settling
        // (plugged in, not charging → charging), and the plug event already says enough.
        let text = snap.statusText
        if now.timeIntervalSince(plugChangedAt) < Self.settle * 2 {
            status = text
            pendingStatus = nil
        } else if text == status {
            pendingStatus = nil
        } else if let pending = pendingStatus, pending.text == text {
            if now.timeIntervalSince(pending.since) >= Self.settle {
                emit(.status, "\(status) → \(text)", at: pending.since)
                status = text
                pendingStatus = nil
            }
        } else {
            pendingStatus = (text, now)
        }

        if ambient.thermalState != thermalState {
            emit(.thermal, "Thermal state \(ProcessInfo.ThermalState(rawValue: thermalState)?.name ?? "?") → \(ambient.thermal.name)")
            thermalState = ambient.thermalState
        }
        if let p = ambient.thermalPressure, p != thermalPressure {
            if let old = thermalPressure {
                emit(.thermal, "Thermal pressure \(ThermalPressure.name(old)) → \(ThermalPressure.name(p))")
            }
            thermalPressure = p
        }

        if let t = snap.batteryTemperatureC {
            let band = Self.band(t, from: tempBand)
            if band != tempBand {
                let detail: String
                switch (band, band > tempBand) {
                case (2, _): detail = String(format: "Battery ≥ %.0f °C (%.1f)", Self.batteryHotC, t)
                case (1, true): detail = String(format: "Battery ≥ %.0f °C (%.1f)", Self.batteryWarmC, t)
                case (1, false): detail = String(format: "Battery below %.0f °C (%.1f)", Self.batteryHotC, t)
                default: detail = String(format: "Battery below %.0f °C (%.1f)", Self.batteryWarmC, t)
                }
                emit(.batteryTemp, detail)
                tempBand = band
            }
        }

        // Brightness: once it has moved a step from the last logged level, wait for it to
        // settle, then log where it ended up.
        if let b = ambient.brightness {
            if let last = brightness {
                if abs(b - last) >= Self.brightnessStep {
                    if let movedAt = brightnessMovedAt {
                        if now.timeIntervalSince(movedAt) >= Self.settle {
                            emit(.brightness, String(format: "Brightness %.0f%% → %.0f%%", last * 100, b * 100), at: movedAt)
                            brightness = b
                            brightnessMovedAt = nil
                        }
                    } else {
                        brightnessMovedAt = now
                    }
                } else {
                    brightnessMovedAt = nil
                }
            } else {
                brightness = b
            }
        }

        if let dark = ambient.isDark, dark != isDark {
            if isDark != nil { emit(.appearance, dark ? "Dark mode" : "Light mode") }
            isDark = dark
        }

        return events
    }

    /// 0 normal, 1 warm, 2 hot. Moving down a band needs a small drop below its threshold.
    private static func band(_ t: Double) -> Int { band(t, from: 0) }

    private static func band(_ t: Double, from current: Int) -> Int {
        let up = t >= batteryHotC ? 2 : (t >= batteryWarmC ? 1 : 0)
        if up >= current { return up }
        let thresholds = [batteryWarmC, batteryHotC]
        var band = current
        while band > 0, t < thresholds[band - 1] - tempHysteresis { band -= 1 }
        return band
    }
}
