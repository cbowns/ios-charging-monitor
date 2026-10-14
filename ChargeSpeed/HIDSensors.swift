import Foundation

/// Reads Apple's vendor power and temperature sensors through the private
/// `IOHIDEventSystemClient` API. On iOS 26 a sandboxed app can create one client
/// and copy sensor events from it; additional clients in the same process return
/// NaN, so a single instance is created once and reused. Not thread-safe: `SensorSampler`
/// confines it to one queue. Each sensor costs ~1.1 ms to read (iPhone 14 Pro, iOS 27).
///
/// Sensor names seen on iPhone 17 Pro Max (usage 2 = current in A, 3 = voltage in V):
///   Charger VQ0u / IQ0u   USB-C input voltage / current
///   Charger VQ1u          wireless (MagSafe) input voltage
///   Charger IQ0B          current delivered to the battery
///   Charger VQ0l, PMU VP0u  battery-side voltages
///   gas gauge battery     battery temperature (usage page 0xff00, usage 5)
final class HIDSensors {
    struct Reading: Identifiable {
        let id: Int
        let name: String
        /// HID usage: 2 = current (A), 3 = voltage (V), 4 = ambient light (lux), 5 = temperature (°C).
        let usage: Int
        /// The latest value, or the mean over the sampling window for fast-sampled sensors.
        let value: Double
        /// Min/max/sample count over the window, for fast-sampled sensors.
        var spread: Spread?

        struct Spread {
            let min: Double
            let max: Double
            let count: Int
        }

        var formatted: String {
            switch usage {
            case 2: return String(format: "%.3f A", value)
            case 3: return String(format: "%.3f V", value)
            case 4: return String(format: "%.0f lux", value)
            case 5: return Formatting.temperature(value)
            default: return String(format: "%.3f", value)
            }
        }
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double
    private typealias GetIntegerFn = @convention(c) (CFTypeRef, Int32) -> Int

    private static let powerEventType: Int64 = 25        // kIOHIDEventTypePower
    private static let temperatureEventType: Int64 = 15  // kIOHIDEventTypeTemperature
    private static let ambientLightEventType: Int64 = 12 // kIOHIDEventTypeAmbientLightSensor

    private struct Service {
        let ref: CFTypeRef
        let name: String
        let usage: Int
        let eventType: Int64
    }

    private let client: CFTypeRef
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let getInteger: GetIntegerFn?
    private var services: [Service] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        self.client = client
        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.getInteger = sym("IOHIDEventGetIntegerValue", GetIntegerFn.self)
        rescan()
    }

    /// Re-enumerates sensor services. Cheap enough to call occasionally.
    func rescan() {
        var found: [Service] = []
        // Apple vendor power sensors (usage page 0xff08): usage 2 = current, 3 = voltage.
        found += discover(matching: ["PrimaryUsagePage": 0xff08], eventType: Self.powerEventType)
        // Temperature sensors: usage page 0xff00, usage 5.
        found += discover(matching: ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5], eventType: Self.temperatureEventType)
        // Ambient light sensor: usage page 0xff00, usage 4; event field 0 is the level in lux.
        // Unverified on iOS: if the sandbox refuses it, it just never returns a reading.
        found += discover(matching: ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4], eventType: Self.ambientLightEventType)
        services = found
    }

    var isEmpty: Bool { services.isEmpty }

    struct ServiceInfo: Equatable {
        let name: String
        let usage: Int
    }

    /// Every discovered sensor in `Reading.id` order, including ones currently returning NaN.
    var catalog: [ServiceInfo] { services.map { ServiceInfo(name: $0.name, usage: $0.usage) } }

    private func discover(matching: [String: Any], eventType: Int64) -> [Service] {
        setMatching(client, matching as CFDictionary)
        let refs = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return refs.map { ref in
            let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            let usage = (copyProperty(ref, "PrimaryUsage" as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            return Service(ref: ref, name: name, usage: usage, eventType: eventType)
        }
    }

    /// Looks for a readable ambient light sensor and dumps every field of its light events, to
    /// find which (if any) carries lux. Matching on an empty dictionary returns no services on
    /// iOS, so each candidate usage page/usage is asked for explicitly. Changes the client's
    /// matching, so it rescans afterwards. Call only from the sampler queue.
    func probeAmbientLight() -> String {
        defer { rescan() }
        func prop(_ ref: CFTypeRef, _ key: String) -> Any? { copyProperty(ref, key as CFString)?.takeRetainedValue() }
        func services(_ matching: [String: Any]) -> [CFTypeRef] {
            setMatching(client, matching as CFDictionary)
            return copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        }

        var lines = ["Services per usage page/usage (names, up to 4):"]
        var candidates: [(label: String, ref: CFTypeRef)] = []
        // Apple vendor page 0xff00 (temps are usage 5, ambient light is usage 4), the power page
        // 0xff08, and the standard HID sensor page 0x20 (0x41 = ambient light sensor).
        var matchings: [(String, [String: Any])] = (1...16).map { ("0xff00/\($0)", ["PrimaryUsagePage": 0xff00, "PrimaryUsage": $0]) }
        matchings += [("0xff08/*", ["PrimaryUsagePage": 0xff08]),
                      ("0x20/*", ["PrimaryUsagePage": 0x20]),
                      ("0x20/0x41", ["PrimaryUsagePage": 0x20, "PrimaryUsage": 0x41])]
        for (label, matching) in matchings {
            let found = services(matching)
            guard !found.isEmpty else { continue }
            let names = found.map { prop($0, "Product") as? String ?? "?" }
            lines.append("  \(label): \(found.count) · " + names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", …" : ""))
            if label == "0xff00/4" || label.hasPrefix("0x20") {
                candidates += zip(names, found).map { ("\(label) \($0)", $1) }
            } else {
                candidates += zip(names, found).filter { $0.0.lowercased().contains("als") || $0.0.lowercased().contains("light") }
                    .map { ("\(label) \($0)", $1) }
            }
        }
        lines.append("")
        if candidates.isEmpty { lines.append("No light-sensor services visible to this app.") }
        for (label, ref) in candidates {
            guard let event = copyEvent(ref, Self.ambientLightEventType, 0, 0)?.takeRetainedValue() else {
                lines.append("\(label): no ambient-light event (refused or not an ALS)")
                continue
            }
            let base = Int32(Self.ambientLightEventType << 16)
            let fields = (0..<16).map { i -> String in
                let f = getFloat(event, base + Int32(i))
                let n = getInteger?(event, base + Int32(i))
                return "\(i)=" + (f.isFinite ? String(format: "%.4g", f) : "nan") + (n.map { "/\($0)" } ?? "")
            }
            lines.append("\(label) light fields (float/int): " + fields.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// Current values of every discovered sensor. Sensors that return NaN are skipped.
    func read() -> [Reading] { read(Array(services.indices)) }

    /// Current values of the sensors at these catalog indices.
    func read(_ ids: [Int]) -> [Reading] {
        ids.compactMap { index in
            guard index < services.count else { return nil }
            let service = services[index]
            guard let event = copyEvent(service.ref, service.eventType, 0, 0)?.takeRetainedValue() else { return nil }
            let value = getFloat(event, Int32(service.eventType << 16))
            guard value.isFinite else { return nil }
            return Reading(id: index, name: service.name, usage: service.usage, value: value)
        }
    }
}
