import SwiftUI
import CoreLocation

/// The background-recording setting and whether it's in effect.
struct BackgroundRecordingSection: View {
    @ObservedObject var keepalive: BackgroundKeepalive

    var body: some View {
        Section {
            Toggle(isOn: $keepalive.isEnabled) {
                HStack {
                    Label("Background recording", systemImage: keepalive.isRunning ? "location.fill" : "location.slash")
                    Spacer()
                    Text(status.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status.color)
                }
            }
            if needsSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } footer: {
            Text(status.detail)
        }
    }

    private var needsSettings: Bool {
        keepalive.isEnabled && (keepalive.authorization == .denied || keepalive.authorization == .restricted)
    }

    private var status: (label: String, color: Color, detail: String) {
        if !keepalive.isEnabled {
            return ("Off", .secondary, "Polling and recording stop when you leave the app.")
        }
        if keepalive.isRunning {
            var detail = "Keeps polling and recording while locked or in another app, using coarse location to stay running. Locations are not stored."
            if let error = keepalive.lastError { detail += " Last location error: \(error)" }
            return ("Active", .green, detail)
        }
        switch keepalive.authorization {
        case .notDetermined:
            return ("Waiting", .orange, "Allow location access to record in the background.")
        case .denied, .restricted:
            return ("No access", .red, "Location access is off for ChargeSpeed, so it stops when you leave the app.")
        default:
            return ("Stopped", .orange, keepalive.lastError ?? "Location updates aren't running.")
        }
    }
}
