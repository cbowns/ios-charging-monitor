import ActivityKit
import Foundation

/// Runs the charging Live Activity: starts it while plugged in, updates it from the monitor's
/// ticks, ends it at unplug. ActivityKit throttles frequent updates (more so from a background
/// app), so it sends at most one update every `minInterval`, and only when the shown values
/// change; a status or percent change goes out at once.
@MainActor
final class LiveActivityController {
    typealias State = ChargeActivityAttributes.ContentState

    private var activity: Activity<ChargeActivityAttributes>?
    private var lastSent: State?
    private var lastSentAt: Date = .distantPast
    private var lastStartAttempt: Date = .distantPast
    /// The last error ActivityKit returned when starting, for the console and the UI.
    private(set) var lastError: String?

    private static let minInterval: TimeInterval = 5
    private static let startRetryInterval: TimeInterval = 30
    /// The Lock Screen marks the activity stale if no update arrives in this long (app suspended).
    private static let staleAfter: TimeInterval = 60

    init() {
        // An activity outlives the app; pick up the one from the previous launch.
        let existing = Activity<ChargeActivityAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(_ snap: PowerSnapshot, sessionStart: Date?) {
        guard snap.externalConnected else {
            end()
            return
        }
        let state = State(snap)
        let now = Date()
        guard let activity else {
            start(state, sessionStart: sessionStart ?? now, now: now)
            return
        }
        // Swiped away (or ended by the system): stay away until the next plug-in.
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        guard state != lastSent else { return }
        let urgent = state.status != lastSent?.status || state.percent != lastSent?.percent
        guard urgent || now.timeIntervalSince(lastSentAt) >= Self.minInterval else { return }
        lastSent = state
        lastSentAt = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    private func start(_ state: State, sessionStart: Date, now: Date) {
        guard now.timeIntervalSince(lastStartAttempt) >= Self.startRetryInterval else { return }
        lastStartAttempt = now
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            report("Live Activities are turned off for ChargeSpeed")
            return
        }
        do {
            activity = try Activity.request(
                attributes: ChargeActivityAttributes(start: sessionStart),
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter)))
            lastSent = state
            lastSentAt = now
            lastError = nil
            #if DEBUG
            print("LIVEACTIVITY started \(activity?.id ?? "?")")
            #endif
        } catch {
            report("start failed: \(error)")
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        lastStartAttempt = .distantPast
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #if DEBUG
        print("LIVEACTIVITY ended \(activity.id)")
        #endif
    }

    private func report(_ message: String) {
        lastError = message
        #if DEBUG
        print("LIVEACTIVITY \(message)")
        #endif
    }
}

extension ChargeActivityAttributes.ContentState {
    /// Rounded to what the Lock Screen shows, so equal states mean nothing visible changed.
    init(_ snap: PowerSnapshot) {
        let wireless = snap.isWirelessInput
        let input = wireless ? nil : snap.chargerInputWatts
        self.init(watts: (input ?? snap.batteryWatts).map(Self.round),
                  source: wireless ? snap.wirelessKind : (input == nil ? "battery" : "USB-C"),
                  batteryWatts: snap.batteryWatts.map(Self.round),
                  percent: snap.percent,
                  batteryTemperatureC: snap.batteryTemperatureC.map(Self.round),
                  status: snap.fullyCharged ? "Charged"
                      : snap.isChargingOnHold ? "On hold"
                      : snap.isCharging ? "Charging" : "Not charging")
    }

    private static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
