import SwiftUI

@main
struct ChargeSpeedApp: App {
    @StateObject private var monitor = PowerMonitor()
    @StateObject private var keepalive = BackgroundKeepalive()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, keepalive: keepalive)
        }
    }
}
