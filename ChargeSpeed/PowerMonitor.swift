import Foundation
import Combine
import UIKit

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot?
    @Published private(set) var errorMessage: String?
    /// Last ~2 minutes of the headline watts, one sample per refresh.
    @Published private(set) var history: [Double] = []
    /// Charge power estimated from how fast the percentage moves. Fallback for
    /// devices where neither the IOKit registry nor the HID sensors give current.
    @Published private(set) var estimate: RateEstimate?
    /// Optimized Battery Charging / charge limit / clean energy settings from PowerUI.
    @Published private(set) var smartCharge: SmartChargeStatus?
    /// IOReturn from the last `IOPSCopyChargeStatus` call; nonzero means powerd refused.
    @Published private(set) var chargeStatusError: Int32 = 0
    /// Darwin notification state for smart-charge status changes; -1 when unavailable.
    @Published private(set) var smartChargeNotifyState: Int64 = -1
    /// Most recent observed charging hold, persisted across launches.
    @Published private(set) var lastHold: HoldObservation?
    /// Plug, profile, thermal and display changes, oldest first (last 500).
    @Published private(set) var events: [ChargeEvent] = []
    @Published private(set) var ambient: Ambient?
    /// Battery watts and voltage per tick, for the tappable charts.
    @Published private(set) var series = SeriesStore()
    /// Every profile the current adapter has reported since it was attached, oldest first.
    /// Wired PD chargers advertise their menu up front; MagSafe and Qi only reveal theirs as
    /// they step up, so this is the only way to see them.
    @Published private(set) var seenProfiles: [SeenProfile] = []
    private var seenProfilesAdapter: String?
    private var lastProfileTick: Date?

    struct SeenProfile: Identifiable {
        let description: String
        let firstSeen: Date
        var lastSeen: Date
        var duration: TimeInterval
        var id: String { description }
    }
    private var detector = EventDetector()
    private static let eventLimit = 500

    struct HoldObservation: Codable {
        let percent: Int
        let start: Date
        var end: Date?
    }

    /// iOS's own thermal verdict; `.serious` and `.critical` mean the system is throttling.
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    var isThrottling: Bool { thermalState == .serious || thermalState == .critical }

    /// Highest charger input power seen since the last reset, persisted across launches.
    @Published private(set) var peak: PeakRecord?
    /// Identity of the current charging session, persisted so a relaunch mid-session keeps the peak.
    /// A session starts at plug-in and survives reaching full and topping off; it ends at unplug.
    struct ChargingSession: Codable {
        var start: Date
        var adapterIdentity: String?
        var lastSeenPluggedIn: Bool
        var lastSeenPercent: Int?
    }
    private var session: ChargingSession?
    private var lastPluggedIn: Bool?
    private static let sessionKey = "chargingSession"

    struct PeakRecord: Codable {
        let watts: Double
        let date: Date
        let adapter: String?
        /// Which measurement this was, e.g. "from charger (USB-C)" or "into battery (MagSafe)".
        var label: String?
    }

    /// Last two headline samples, for the median-of-three glitch filter.
    private var recentSamples: [Double] = []
    private static let peakKey = "peakRecord"

    private var currentHold: HoldObservation?
    private var holdCandidateSince: Date?
    private var lastExternalConnected: Bool?
    private var externalChangedAt: Date = .distantPast
    /// A hold must persist this long before it counts; plug-in transitions look like a hold for a second or two.
    private static let holdDebounce: TimeInterval = 45
    private static let holdKey = "lastHoldObservation"

    struct RateEstimate {
        let watts: Double
        let steps: Int
        let window: TimeInterval
    }

    /// Usable battery energy used to convert %/h into watts, from the device profile.
    var batteryWattHours: Double { profile.batteryWattHours }
    let profile: DeviceProfile

    /// False when replaying a recording: no hardware readers, nothing persisted or recorded.
    let isLive: Bool
    let reader: IOKitBattery?
    /// Shared: a second `IOHIDEventSystemClient` in the same process reads NaN.
    private static let sharedSampler = HIDSensors().map(SensorSampler.init)
    let sampler: SensorSampler?
    private let smartChargeReader: SmartChargeReader?
    let recorder: RecordingWriter?
    private var smartChargeInFlight = false
    private var task: Task<Void, Never>?
    private let interval: Duration = .seconds(1)
    /// powerd, registry and sensor-window reads happen here so the main thread only updates UI.
    private static let gatherQueue = DispatchQueue(label: "com.gregwilson.chargespeed.gather", qos: .userInitiated)
    /// Screen brightness, refreshed on `UIScreen.brightnessDidChangeNotification`; reading it
    /// is a synchronous call to backboardd, so it isn't polled.
    private var brightness: Double?
    private var brightnessObserver: NSObjectProtocol?
    private let historyLimit = 120
    private var refreshCount = 0
    private var percentLog: [(date: Date, percent: Int)] = []
    private var lastCharging: Bool?

    /// Live monitor: reads the hardware, persists peak/hold/session, records to disk.
    init() {
        isLive = true
        profile = .current
        reader = IOKitBattery()
        sampler = Self.sharedSampler
        smartChargeReader = SmartChargeReader()
        recorder = RecordingWriter()
        thermalState = ProcessInfo.processInfo.thermalState
        if let data = UserDefaults.standard.data(forKey: Self.holdKey),
           let hold = try? JSONDecoder().decode(HoldObservation.self, from: data) {
            // Drop blips recorded before debouncing existed.
            if let end = hold.end, end.timeIntervalSince(hold.start) < Self.holdDebounce {
                UserDefaults.standard.removeObject(forKey: Self.holdKey)
            } else {
                lastHold = hold
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.peakKey),
           let record = try? JSONDecoder().decode(PeakRecord.self, from: data) {
            peak = record
        }
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let saved = try? JSONDecoder().decode(ChargingSession.self, from: data) {
            session = saved
        }
    }

    /// Replay monitor: starts empty and is fed recorded snapshots through `ingest`.
    static func forReplay(profile: DeviceProfile) -> PowerMonitor { PowerMonitor(replay: profile) }

    private init(replay profile: DeviceProfile) {
        isLive = false
        self.profile = profile
        reader = nil
        sampler = nil
        smartChargeReader = nil
        recorder = nil
    }

    private func save<T: Encodable>(_ value: T?, forKey key: String) {
        guard isLive else { return }
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func resetPeak() {
        peak = nil
        recentSamples.removeAll()
        save(peak, forKey: Self.peakKey)
    }

    func start() {
        guard isLive else { return }
        sampler?.start()
        task?.cancel()
        observeBrightness()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let next = ContinuousClock.now + (self?.interval ?? .seconds(1))
                await self?.refresh()
                try? await Task.sleep(until: next)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        sampler?.stop()
    }

    private struct Gathered {
        let snapshot: PowerSnapshot
        let catalog: [HIDSensors.ServiceInfo]
        let chargeStatusError: Int32
    }

    /// Reads powerd, the registry and the latest sensor window on `gatherQueue`.
    private nonisolated static func gather(_ reader: IOKitBattery, _ sampler: SensorSampler?) -> Gathered? {
        guard let props = reader.readProperties() else { return nil }
        let sources = reader.readPowerSources()
        let internalBattery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first
        let window = sampler?.take()
        let snap = PowerSnapshot(date: .now,
                                 raw: props,
                                 powerSource: internalBattery,
                                 adapterDetails: reader.readAdapterDetails(),
                                 sensors: window?.readings ?? [],
                                 chargeStatus: reader.readChargeStatus())
        return Gathered(snapshot: snap, catalog: window?.catalog ?? [], chargeStatusError: reader.chargeStatusError)
    }

    func refresh() async {
        guard let reader else {
            errorMessage = "IOKit could not be loaded on this device."
            return
        }
        let sampler = sampler
        let gathered = await withCheckedContinuation { continuation in
            Self.gatherQueue.async { continuation.resume(returning: Self.gather(reader, sampler)) }
        }
        guard let gathered else {
            errorMessage = "No IOPMPowerSource service found."
            return
        }
        errorMessage = nil
        refreshCount += 1
        let snap = gathered.snapshot
        chargeStatusError = gathered.chargeStatusError
        let ambient = currentAmbient()
        recorder?.record(snap, catalog: gathered.catalog, ambient: ambient)
        ingest(snap, ambient)
        #if DEBUG
        BackgroundProbe.log(snap, recording: recorder?.url)
        #endif

        let notifyState = SmartChargeNotificationState()
        if notifyState != smartChargeNotifyState {
            #if DEBUG
            print("SMARTCHARGE notify state \(smartChargeNotifyState) -> \(notifyState)")
            #endif
            smartChargeNotifyState = notifyState
        }
        if refreshCount % 10 == 1 { refreshSmartCharge() }

        #if DEBUG
        if refreshCount == 1 || refreshCount % 15 == 0 {
            let readings = snap.sensors.map { "\($0.name)=\($0.formatted)" }.joined(separator: ", ")
            print("CHARGESTATUS kr=0x\(String(UInt32(bitPattern: reader.chargeStatusError), radix: 16)) dict=\(String(describing: snap.chargeStatus))")
            print("TICK \(refreshCount) status=\(snap.statusText) primary=\(String(describing: snap.primaryWatts)) battery=\(String(describing: snap.batteryWatts)) sensors=[\(readings)]")
        }
        #endif
    }

    /// Everything derived from one tick, shared by live polling and replay.
    func ingest(_ snap: PowerSnapshot, _ ambient: Ambient) {
        snapshot = snap
        if ambient != self.ambient { self.ambient = ambient }
        if ambient.thermal != thermalState { thermalState = ambient.thermal }
        updateEstimate(snap)
        updateHold(snap)
        updateSession(snap)
        updatePeak(snap)
        updateSeenProfiles(snap)
        series.append(snap)

        let new = detector.detect(snap, ambient)
        if !new.isEmpty {
            for event in new { recorder?.record(event) }
            events.append(contentsOf: new)
            if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
        }

        let sample = snap.primaryWatts?.value ?? estimate?.watts
        if let sample {
            history.append(sample)
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        }
    }

    private func currentAmbient() -> Ambient {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if brightness == nil, let scene { brightness = Double(scene.screen.brightness) }
        return Ambient(thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                       brightness: brightness,
                       isDark: scene.map { $0.traitCollection.userInterfaceStyle == .dark },
                       appState: UIApplication.shared.applicationState.rawValue,
                       thermalPressure: ThermalPressure.current())
    }

    private func observeBrightness() {
        guard brightnessObserver == nil else { return }
        brightnessObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let screen = note.object as? UIScreen else { return }
            let value = Double(screen.brightness)
            MainActor.assumeIsolated { self?.brightness = value }
        }
    }

    /// PowerUI calls go over XPC synchronously, so they run off the main actor.
    private func refreshSmartCharge() {
        guard let reader = smartChargeReader, !smartChargeInFlight else {
            if smartChargeReader == nil, smartCharge == nil {
                let status = SmartChargeStatus()
                status.available = false
                status.errorMessage = "PowerUI framework unavailable"
                smartCharge = status
            }
            return
        }
        smartChargeInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let status = reader.read()
            await MainActor.run {
                guard let self else { return }
                self.smartCharge = status
                self.smartChargeInFlight = false
                #if DEBUG
                if self.refreshCount <= 1 {
                    print("SMARTCHARGE available=\(status.available) obc=\(status.obcEnabled) mcl=\(status.mclEnabled) limit=\(status.mclLimit) deoc=\(status.deocEnabled) current=\(status.currentChargeLimit) recommended=\(status.recommendedChargeLimit) engaged=\(status.obcEngaged) engagedLimit=\(status.engagedChargeLimit) override=\(status.chargingOverrideAllowed) ui=\(status.uiState) supported=\(status.obcSupported)/\(status.mclSupported)/\(status.deocSupported) deadline=\(String(describing: status.fullChargeDeadline)) errors=\(status.callErrors)")
                    print("SMARTCHARGE status=\(String(describing: status.rawStatus))")
                }
                #endif
            }
        }
    }

    func rawDump() -> String {
        guard let snap = snapshot else { return "" }
        var text = "ChargeSpeed \(BuildInfo.summary)\n\nIOPMPowerSource:\n" + dump(snap.raw)
        if let cs = snap.chargeStatus { text += "\n\nChargeStatus:\n" + dump(cs) }
        if let sc = smartCharge {
            text += "\n\nSmartCharge: obc=\(sc.obcEnabled) mcl=\(sc.mclEnabled) limit=\(sc.mclLimit) deoc=\(sc.deocEnabled) engaged=\(sc.obcEngaged) engagedLimit=\(sc.engagedChargeLimit) ui=\(sc.uiState) errors=\(sc.callErrors)"
            if let raw = sc.rawStatus as? [String: Any] { text += "\n" + dump(raw) }
        }
        if let ps = snap.powerSource { text += "\n\nIOPS:\n" + dump(ps) }
        if let ad = snap.adapterDetails { text += "\n\nAdapter:\n" + dump(ad) }
        if !snap.sensors.isEmpty {
            text += "\n\nSensors:\n" + snap.sensors.map { "\($0.name) = \($0.formatted)" }.joined(separator: "\n")
        }
        return text
    }

    private func dump(_ dict: [String: Any]) -> String {
        dict.keys.sorted().map { "\($0) = \(String(describing: dict[$0]!))" }.joined(separator: "\n")
    }

    /// Records when the phone sits on a charging hold and at what level, so the limit
    /// (80/85/90/95 % or Optimized Battery Charging's 80 %) can be read off later.
    private func updateHold(_ snap: PowerSnapshot) {
        if lastExternalConnected != snap.externalConnected {
            lastExternalConnected = snap.externalConnected
            externalChangedAt = snap.date
        }
        let settled = snap.date.timeIntervalSince(externalChangedAt) >= Self.holdDebounce
        if snap.isChargingOnHold, settled, let p = snap.percent {
            if holdCandidateSince == nil { holdCandidateSince = snap.date }
            if currentHold == nil, let since = holdCandidateSince,
               snap.date.timeIntervalSince(since) >= Self.holdDebounce {
                currentHold = HoldObservation(percent: p, start: since, end: nil)
                lastHold = currentHold
                persistHold()
            }
        } else {
            holdCandidateSince = nil
            if currentHold != nil {
                currentHold?.end = snap.date
                lastHold = currentHold
                persistHold()
                currentHold = nil
            }
        }
    }

    /// Detects plug-in events and resets the peak at the start of each charging session.
    /// While running, any unplugged → plugged transition is a new session. On the first tick after
    /// launch, the persisted session is continued only if the phone was still plugged in when last
    /// seen, the adapter is the same, and the level has not dropped (i.e. no unplug happened while
    /// the app was closed).
    private func updateSession(_ snap: PowerSnapshot) {
        let pluggedIn = snap.externalConnected
        defer { lastPluggedIn = pluggedIn }

        if pluggedIn {
            var isNew = false
            if lastPluggedIn == false {
                isNew = true
            } else if lastPluggedIn == nil {
                if let saved = session, saved.lastSeenPluggedIn,
                   saved.adapterIdentity == snap.adapterIdentity,
                   (snap.percent ?? 0) >= (saved.lastSeenPercent ?? 0) - 1 {
                    isNew = false
                } else {
                    isNew = true
                }
            }
            if isNew {
                seenProfiles.removeAll()
                peak = nil
                recentSamples.removeAll()
                history.removeAll()
                save(peak, forKey: Self.peakKey)
                session = ChargingSession(start: snap.date, adapterIdentity: snap.adapterIdentity,
                                          lastSeenPluggedIn: true, lastSeenPercent: snap.percent)
                persistSession()
            } else if var current = session {
                if current.adapterIdentity == nil { current.adapterIdentity = snap.adapterIdentity }
                if !current.lastSeenPluggedIn || current.lastSeenPercent != snap.percent {
                    current.lastSeenPluggedIn = true
                    current.lastSeenPercent = snap.percent
                    session = current
                    persistSession()
                } else {
                    session = current
                }
            } else {
                session = ChargingSession(start: snap.date, adapterIdentity: snap.adapterIdentity,
                                          lastSeenPluggedIn: true, lastSeenPercent: snap.percent)
                persistSession()
            }
        } else if var current = session, current.lastSeenPluggedIn {
            current.lastSeenPluggedIn = false
            current.lastSeenPercent = snap.percent
            session = current
            persistSession()
        }
    }

    private func persistSession() {
        if let session { save(session, forKey: Self.sessionKey) }
    }

    /// Adds the adapter's current profile to `seenProfiles` and credits it with the time since
    /// the last tick. A different adapter starts a fresh list.
    private func updateSeenProfiles(_ snap: PowerSnapshot) {
        defer { lastProfileTick = snap.date }
        guard snap.externalConnected, let description = snap.adapterProfileDescription else { return }
        if let id = snap.adapterIdentity, id != seenProfilesAdapter {
            if seenProfilesAdapter != nil { seenProfiles.removeAll() }
            seenProfilesAdapter = id
        }
        // Gaps (app suspended, replay seeks) don't count as time in the profile.
        let elapsed = lastProfileTick.map { min(max(snap.date.timeIntervalSince($0), 0), 5) } ?? 0
        if let i = seenProfiles.firstIndex(where: { $0.description == description }) {
            seenProfiles[i].lastSeen = snap.date
            seenProfiles[i].duration += elapsed
        } else {
            seenProfiles.append(SeenProfile(description: description, firstSeen: snap.date,
                                            lastSeen: snap.date, duration: 0))
        }
    }

    /// Records the peak of the headline number (charger input on USB-C, battery input on
    /// MagSafe where no input current sensor exists) for the current charging session. Uses the
    /// median of the last three samples so a single glitchy reading cannot set it.
    private func updatePeak(_ snap: PowerSnapshot) {
        guard snap.externalConnected, let primary = snap.primaryWatts, primary.value > 0 else {
            recentSamples.removeAll()
            return
        }
        recentSamples.append(primary.value)
        if recentSamples.count > 3 { recentSamples.removeFirst(recentSamples.count - 3) }
        guard recentSamples.count == 3 else { return }
        let candidate = recentSamples.sorted()[1]
        if candidate > (peak?.watts ?? 0) {
            peak = PeakRecord(watts: candidate, date: snap.date,
                              adapter: snap.adapterName ?? snap.adapterDescription,
                              label: primary.label)
            save(peak, forKey: Self.peakKey)
        }
    }

    private func persistHold() {
        if let lastHold { save(lastHold, forKey: Self.holdKey) }
    }

    /// Tracks 1% transitions and converts the slope into watts.
    /// The first logged sample is mid-percent, so at least two transitions are needed.
    private func updateEstimate(_ snap: PowerSnapshot) {
        guard let percent = snap.percent else { estimate = nil; return }
        if lastCharging != snap.isCharging {
            lastCharging = snap.isCharging
            percentLog.removeAll()
            estimate = nil
        }
        if percentLog.last?.percent != percent {
            percentLog.append((snap.date, percent))
            if percentLog.count > 7 { percentLog.removeFirst(percentLog.count - 7) }
        }
        let transitions = percentLog.dropFirst()
        guard transitions.count >= 2, let first = transitions.first, let last = transitions.last else { return }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0 else { return }
        let deltaPercent = Double(last.percent - first.percent)
        estimate = RateEstimate(watts: deltaPercent / 100 * batteryWattHours / hours,
                                steps: transitions.count - 1,
                                window: last.date.timeIntervalSince(first.date))
    }
}
