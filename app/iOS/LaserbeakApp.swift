import SwiftUI

// iOS-версія. Той самий Shared-код, що й на маку: моделі, клієнт, екрани.
// Різниця одна — ноут треба спершу знайти в мережі.

@main
struct LaserbeakApp: App {
    @StateObject private var discovery = DiscoveryService()
    @StateObject private var client = DaemonClient()

    var body: some Scene {
        WindowGroup {
            PhoneRootView(client: client, discovery: discovery)
                .task {
                    discovery.start()
                    client.start()
                }
        }
    }
}
