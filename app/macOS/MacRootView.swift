import SwiftUI
import AppKit

// Головне вікно програми на маку.

struct MacRootView: View {
    @ObservedObject var client: DaemonClient

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBar(client: client)
            Divider()
            ProjectsView(client: client)
        }
    }
}

/// Те, що видно з меню-бару: коротка зведення і кілька дій.
struct MenuBarContent: View {
    @ObservedObject var client: DaemonClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let state = client.state, client.isConnected {
            let live = state.sortedProjects.filter(\.isLive)

            if live.isEmpty {
                Text("Активних сесій немає")
            } else {
                ForEach(live) { project in
                    Text("\(project.displayName) — \(project.sessionCountText)")
                    ForEach(project.sessions.sorted { $0.since < $1.since }) { session in
                        Text("    \(menuLine(for: session))")
                    }
                }
            }
        } else {
            Text("Немає зв'язку з демоном")
        }

        Divider()

        Button("Відкрити вікно") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        // Не просто terminate: демон піднімає програму назад, якщо вона
        // замовкла. Свідомий вихід лишає позначку, яка це зупиняє.
        Button("Вийти") { AppPresence.quitForReal() }
            .keyboardShortcut("q")
    }

    private func menuLine(for session: Session) -> String {
        var line = "\(session.title) — \(session.state.title)"
        if let duration = session.durationText { line += " (\(duration))" }
        return line
    }
}
