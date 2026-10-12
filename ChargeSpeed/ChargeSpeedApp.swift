import SwiftUI

@main
struct ChargeSpeedApp: App {
    @StateObject private var monitor = PowerMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor)
        }
    }
}
