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

    /// Lists the vendor-page HID services and anything that looks like a light sensor, and dumps
    /// every field of their ambient-light events, to find which (if any) carries lux. Changes the
    /// client's matching, so it rescans afterwards. Call only from the sampler queue.
    func probeAmbientLight() -> String {
        defer { rescan() }
        var lines: [String] = []
        setMatching(client, [:] as CFDictionary)
        let all = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        func prop(_ ref: CFTypeRef, _ key: String) -> Any? { copyProperty(ref, key as CFString)?.takeRetainedValue() }
        lines.append("HID services visible: \(all.count)")
        var candidates: [CFTypeRef] = []
        var pages: [String: Int] = [:]
        for ref in all {
            let page = (prop(ref, "PrimaryUsagePage") as? NSNumber)?.intValue ?? -1
            let usage = (prop(ref, "PrimaryUsage") as? NSNumber)?.intValue ?? -1
            let name = prop(ref, "Product") as? String ?? "?"
            pages[String(format: "0x%x/%d", page, usage), default: 0] += 1
            let lower = name.lowercased()
            if (page == 0xff00 && usage == 4) || lower.contains("als") || lower.contains("light") || lower.contains("lux") {
                candidates.append(ref)
                lines.append(String(format: "  candidate: %@ (page 0x%x usage %d)", name, page, usage))
            }
        }
        lines.append("Usage page/usage counts: " + pages.keys.sorted().map { "\($0)×\(pages[$0]!)" }.joined(separator: ", "))
        lines.append("")
        for ref in candidates {
            let name = prop(ref, "Product") as? String ?? "?"
            guard let event = copyEvent(ref, Self.ambientLightEventType, 0, 0)?.takeRetainedValue() else {
                lines.append("\(name): no ambient-light event (refused or not an ALS)")
                continue
            }
            let base = Int32(Self.ambientLightEventType << 16)
            let fields = (0..<16).map { i -> String in
                let f = getFloat(event, base + Int32(i))
                let n = getInteger?(event, base + Int32(i))
                return "\(i)=" + (f.isFinite ? String(format: "%.4g", f) : "nan") + (n.map { "/\($0)" } ?? "")
            }
            lines.append("\(name) ambient-light fields (float/int): " + fields.joined(separator: " "))
        }
        if candidates.isEmpty { lines.append("No light-sensor services visible to this app.") }
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
