import SwiftUI
import AppKit

// Програма-значок: живе в меню-барі, у доці й у ⌘Tab її немає
// (LSUIElement у project.yml). Вікно відкривається з меню-бару, а
// закриття вікна нічого не гасить — програма працює далі.
//
// Так і має бути. Вона показує банери від імені Laserbeak і тримає
// меню-бар, тобто мусить працювати завжди; іконка в доці лише вдавала б,
// що її «відкрито», і напрошувалась би на ⌘Q.

@main
struct LaserbeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @StateObject private var client = DaemonClient(baseURL: LocalDaemon.baseURL())
    @StateObject private var router = AppRouter.shared

    init() {
        // До першого вікна: якою мовою малювати, macOS вирішує рано.
        AppLanguage.applyFromConfig()
    }

    var body: some Scene {
        Window("Laserbeak", id: AppRouter.mainWindow) {
            MainWindow(client: client, router: router)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }   // вікно тут одне
        }

        MenuBarExtra {
            MenuBarContent(client: client, router: router)
        } label: {
            MenuBarLabel(client: client)
        }
    }
}

/// Куди дивиться вікно, і як його відкрити звідки завгодно: з меню-бару,
/// з банера, з повторного запуску програми.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    static let mainWindow = "main"

    @Published var section: SidebarItem = .sessions

    /// Відкрити вікно сцени вміє лише SwiftUI зсередини якоїсь вʼюшки.
    /// Дію сюди кладе підпис у меню-барі — він живе весь час роботи
    /// програми, на відміну від самого вікна.
    var openMainWindow: (() -> Void)?

    func show(_ item: SidebarItem? = nil) {
        if let item { section = item }

        if let openMainWindow {
            openMainWindow()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue == Self.mainWindow }?
                .makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeShortcut: Any?

    private var launchedInBackground: Bool {
        CommandLine.arguments.contains("--background")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ми знову тут — отже, вихід уже не в силі. Демон стежить за цією
        // позначкою й доти програму не піднімає.
        AppPresence.clearQuitFlag()

        // Слухати чергу сповіщень треба весь час роботи програми, а не
        // лише поки відкрите вікно.
        NotificationService.shared.start(baseURL: LocalDaemon.baseURL())

        // Разом із доком у програми-значка зникає і смужка меню, а з нею
        // ⌘W. Хрестик у вікні лишається, але рука тягнеться до
        // клавіатури — тому це одне звичне скорочення повертаємо самі.
        closeShortcut = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "w",
                  let window = NSApp.keyWindow
            else { return event }

            window.close()
            return nil
        }

        // Запуск при вході в систему не має відкривати вікно —
        // програма просто починає працювати у фоні. SwiftUI створює
        // вікно сам, тому закриваємо його наступним тактом циклу.
        guard launchedInBackground else { return }
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.close() }
        }
    }

    // Головне для режиму "працює у фоні": хрестик ховає вікно, а не гасить програму.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Іконки в доці немає, але шлях лишається робочим: повторний запуск
    /// програми (Spotlight, `open -a`) не плодить процес, а показує вікно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            Task { @MainActor in AppRouter.shared.show() }
        }
        return true
    }
}

/// Свідомий вихід із програми.
///
/// Демон піднімає програму назад, якщо вона замовкла: без неї банери
/// стають безликими, а меню-бар зникає.
///
/// Але «Вийти» мусить справді вийти, інакше пункт меню виглядає
/// зламаним. Тому лишаємо по собі позначку: доки вона є, демон нас не
/// чіпає. Прибирається сама при наступному запуску — зокрема при вході
/// в систему.
enum AppPresence {
    static let quitFlag = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".laserbeak/app-quit")

    static func quitForReal() {
        FileManager.default.createFile(atPath: quitFlag.path, contents: Data())
        AppLog.write("вихід за командою користувача — демон не піднімати")
        NSApp.terminate(nil)
    }

    static func clearQuitFlag() {
        try? FileManager.default.removeItem(at: quitFlag)
    }
}

/// Демон на цьому ж комп'ютері. Порт читаємо з його конфігу, щоб
/// не розходився, якщо користувач його змінить.
enum LocalDaemon {
    static let dataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".laserbeak")

    static func port() -> Int {
        let url = dataDirectory.appendingPathComponent("config.json")

        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int
        else { return 8787 }

        return port
    }

    static func baseURL() -> URL? {
        URL(string: "http://127.0.0.1:\(port())")
    }
}
