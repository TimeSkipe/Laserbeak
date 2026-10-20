import SwiftUI
import AppKit

/// Значок у меню-барі. Живе весь час роботи програми — тому саме він
/// віддає роутеру вміння відкривати вікно (див. AppRouter).
struct MenuBarLabel: View {
    @ObservedObject var client: DaemonClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(verbatim: client.badge)
            .onAppear {
                AppRouter.shared.openMainWindow = { openWindow(id: AppRouter.mainWindow) }
            }
    }
}

/// Те, що видно з меню-бару: коротке зведення і кілька дій.
struct MenuBarContent: View {
    @ObservedObject var client: DaemonClient
    @ObservedObject var router: AppRouter

    var body: some View {
        if let state = client.state, client.isConnected {
            let live = state.sortedProjects.filter(\.isLive)

            // Кнопки, а не текст: текст у меню — це сірий пункт, по якому
            // нічого не стається, і він виглядає зламаним. Клік відкриває
            // вікно на сесіях.
            if live.isEmpty {
                Text("Активних сесій немає")
            } else {
                ForEach(live) { project in
                    Button {
                        router.show(.sessions)
                    } label: {
                        Text(verbatim: "\(project.displayName) — \(project.sessionCountText)")
                    }
                    ForEach(project.sessions.sorted { $0.since < $1.since }) { session in
                        Button {
                            router.show(.sessions)
                        } label: {
                            Text(verbatim: "    \(menuLine(for: session))")
                        }
                    }
                }
            }

            if state.update.isAvailable {
                Divider()
                Button(String(format: String(localized: "Доступне оновлення (%@)…"), state.update.behindText)) {
                    router.show(.updates)
                }
            }
        } else {
            Text("Немає зв'язку з демоном")
        }

        Divider()

        Button("Відкрити Laserbeak") { router.show(.sessions) }
            .keyboardShortcut("o")

        Button("Налаштування…") { router.show(.general) }
            .keyboardShortcut(",")

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
