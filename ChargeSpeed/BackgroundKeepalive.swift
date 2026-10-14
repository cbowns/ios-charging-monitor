import CoreLocation

/// Keeps the app running in the background and while locked by holding continuous location
/// updates, so the monitor can poll and record a whole charging session. The fixes are
/// discarded; the coarsest accuracy keeps GPS off and lets iOS use Wi-Fi and cell.
@MainActor
final class BackgroundKeepalive: NSObject, ObservableObject {
    /// The user's setting; on by default.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }
    /// True while location updates are running, i.e. the app will keep running in the background.
    @Published private(set) var isRunning = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private static let enabledKey = "backgroundRecording"
    private let manager = CLLocationManager()

    override init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.activityType = .other
        // Paused updates would let iOS suspend the app.
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    /// Starts updates if enabled and allowed, asking for permission the first time. Call from
    /// the foreground: with only When In Use, updates must start while the app is visible.
    func start() {
        guard isEnabled, !isRunning else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
            isRunning = true
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
    }
}

extension BackgroundKeepalive: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            authorization = manager.authorizationStatus
            switch authorization {
            case .authorizedAlways, .authorizedWhenInUse: start()
            default: if isRunning { stop() }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if lastError != nil { lastError = nil }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix yet; updates carry on.
        if (error as? CLError)?.code == .locationUnknown { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated { lastError = message }
    }
}
