import Foundation
import UIKit

/// Recordings are JSON Lines files in Documents/Recordings (visible in the Files app), one
/// object per line, tagged by `type`:
///
///     header   version, start, device, os, app
///     sensors  names, usages: the HID sensor catalog; written at start and whenever it changes
///     dict     key (raw | powerSource | adapterDetails | chargeStatus), value: written when it changes
///     tick     t, v (sensor values in catalog order, null = NaN), th, br, dark, app
///     event    t, kind, detail
///
/// Times are seconds since 1970. Dictionaries hold plist values; Data and Date become
/// {"$data": base64} and {"$date": seconds}.
enum RecordingFormat {
    static let version = 1

    static var directory: URL {
        URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    /// Shortest round-trip text of a value rounded to 4 decimals.
    static func number(_ v: Double) -> String { ((v * 10_000).rounded() / 10_000).description }
    static func time(_ d: Date) -> String { ((d.timeIntervalSince1970 * 1000).rounded() / 1000).description }

    static func encode(_ value: Any) -> Any {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.doubleValue.isFinite ? n : NSNull()
        case let d as Data: return ["$data": d.base64EncodedString()]
        case let d as Date: return ["$date": d.timeIntervalSince1970]
        case let a as [Any]: return a.map(encode)
        case let d as [AnyHashable: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[String(describing: k)] = encode(v) }
            return out
        default: return String(describing: value)
        }
    }

    static func decode(_ value: Any) -> Any {
        switch value {
        case let a as [Any]: return a.map(decode)
        case let d as [String: Any]:
            if d.count == 1, let s = d["$data"] as? String { return Data(base64Encoded: s) ?? Data() }
            if d.count == 1, let t = d["$date"] as? Double { return Date(timeIntervalSince1970: t) }
            return d.mapValues(decode)
        default: return value
        }
    }
}

/// Appends the live stream to a new file per app launch, rolling over every 12 hours.
final class RecordingWriter {
    private static let rollover: TimeInterval = 12 * 3600

    private(set) var url: URL?
    private var handle: FileHandle?
    private var startedAt = Date.distantPast
    private var catalog: [HIDSensors.ServiceInfo]?
    private var dicts: [String: NSDictionary?] = [:]

    deinit { try? handle?.close() }

    func record(_ snap: PowerSnapshot, catalog: [HIDSensors.ServiceInfo], ambient: Ambient) {
        if handle == nil || snap.date.timeIntervalSince(startedAt) > Self.rollover {
            open(at: snap.date)
        }
        let t = RecordingFormat.time(snap.date)
        if catalog != self.catalog {
            self.catalog = catalog
            writeJSON(["type": "sensors", "t": snap.date.timeIntervalSince1970,
                       "names": catalog.map(\.name), "usages": catalog.map(\.usage)])
        }
        let values: [Any?] = [snap.raw, snap.powerSource, snap.adapterDetails, snap.chargeStatus]
        for (key, value) in zip(Recording.dictKeys, values) {
            let dict = (value as? [String: Any]).map { $0 as NSDictionary }
            if let last = dicts[key], last == dict { continue }
            dicts[key] = .some(dict)
            writeJSON(["type": "dict", "t": snap.date.timeIntervalSince1970, "key": key,
                       "value": dict.map { RecordingFormat.encode($0) } ?? NSNull()])
        }

        var slots = [String](repeating: "null", count: catalog.count)
        for r in snap.sensors where r.id < slots.count { slots[r.id] = RecordingFormat.number(r.value) }
        var line = "{\"type\":\"tick\",\"t\":\(t),\"v\":[\(slots.joined(separator: ","))],\"th\":\(ambient.thermalState)"
        if let b = ambient.brightness { line += ",\"br\":\(RecordingFormat.number(b))" }
        if let d = ambient.isDark { line += ",\"dark\":\(d)" }
        if let a = ambient.appState { line += ",\"app\":\(a)" }
        write(line + "}\n")
    }

    func record(_ event: ChargeEvent) {
        writeJSON(["type": "event", "t": event.date.timeIntervalSince1970,
                   "kind": event.kind.rawValue, "detail": event.detail])
    }

    private func open(at date: Date) {
        try? handle?.close()
        handle = nil
        catalog = nil
        dicts = [:]
        startedAt = date
        let dir = RecordingFormat.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: RecordingFormat.fileNameFormatter.string(from: date) + ".jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        self.url = url
        self.handle = handle
        let info = Bundle.main.infoDictionary ?? [:]
        writeJSON(["type": "header", "version": RecordingFormat.version, "start": date.timeIntervalSince1970,
                   "device": Self.modelIdentifier(), "os": UIDevice.current.systemVersion,
                   "app": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"])
    }

    private func writeJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        write(text + "\n")
    }

    private func write(_ text: String) {
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    /// e.g. "iPhone18,2".
    private static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// A recording parsed for replay. Ticks keep only indices into the shared catalogs and
/// dictionaries, so a 12-hour file stays a few tens of MB in memory.
struct Recording {
    struct Frame {
        let date: Date
        /// Sensor values in catalog order; NaN where the sensor had no reading.
        let values: [Double]
        let catalog: Int
        let dicts: [Int]
        let ambient: Ambient
    }

    let url: URL
    let device: String?
    let os: String?
    let catalogs: [[HIDSensors.ServiceInfo]]
    /// Pool of every distinct dictionary value; `Frame.dicts` index it (-1 = none), keyed by `dictKeys`.
    let dictPool: [[String: Any]]
    static let dictKeys = ["raw", "powerSource", "adapterDetails", "chargeStatus"]
    let frames: [Frame]
    let events: [ChargeEvent]

    var start: Date? { frames.first?.date }
    var end: Date? { frames.last?.date }

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        var device: String?, os: String?
        var catalogs: [[HIDSensors.ServiceInfo]] = []
        var pool: [[String: Any]] = []
        var current = [Int](repeating: -1, count: Self.dictKeys.count)
        var frames: [Frame] = []
        var events: [ChargeEvent] = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            // The newest file may end mid-line while it is still being written.
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let date = Date(timeIntervalSince1970: obj["t"] as? Double ?? 0)
            switch type {
            case "header":
                device = obj["device"] as? String
                os = obj["os"] as? String
            case "sensors":
                let names = obj["names"] as? [String] ?? []
                let usages = obj["usages"] as? [Int] ?? []
                catalogs.append(zip(names, usages).map { HIDSensors.ServiceInfo(name: $0, usage: $1) })
            case "dict":
                guard let key = obj["key"] as? String, let slot = Self.dictKeys.firstIndex(of: key) else { continue }
                if let value = RecordingFormat.decode(obj["value"] ?? NSNull()) as? [String: Any] {
                    pool.append(value)
                    current[slot] = pool.count - 1
                } else {
                    current[slot] = -1
                }
            case "tick":
                let raw = obj["v"] as? [Any] ?? []
                let values = raw.map { ($0 as? Double) ?? .nan }
                let ambient = Ambient(thermalState: obj["th"] as? Int ?? 0,
                                      brightness: obj["br"] as? Double,
                                      isDark: obj["dark"] as? Bool,
                                      appState: obj["app"] as? Int)
                frames.append(Frame(date: date, values: values, catalog: catalogs.count - 1,
                                    dicts: current, ambient: ambient))
            case "event":
                if let kind = (obj["kind"] as? String).flatMap(ChargeEvent.Kind.init(rawValue:)) {
                    events.append(ChargeEvent(date: date, kind: kind, detail: obj["detail"] as? String ?? ""))
                }
            default:
                continue
            }
        }
        self.device = device
        self.os = os
        self.catalogs = catalogs
        self.dictPool = pool
        self.frames = frames
        self.events = events
    }

    func snapshot(at index: Int) -> PowerSnapshot {
        let frame = frames[index]
        let catalog = frame.catalog >= 0 ? catalogs[frame.catalog] : []
        let sensors = zip(catalog.indices, frame.values).compactMap { i, v in
            v.isNaN ? nil : HIDSensors.Reading(id: i, name: catalog[i].name, usage: catalog[i].usage, value: v)
        }
        func dict(_ slot: Int) -> [String: Any]? { frame.dicts[slot] >= 0 ? dictPool[frame.dicts[slot]] : nil }
        return PowerSnapshot(date: frame.date, raw: dict(0) ?? [:], powerSource: dict(1),
                             adapterDetails: dict(2), sensors: sensors, chargeStatus: dict(3))
    }
}
