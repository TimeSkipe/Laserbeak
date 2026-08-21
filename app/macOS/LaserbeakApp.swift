import SwiftUI
import AppKit

// Програма-значок: живе в меню-барі, у доці й у ⌘Tab її немає
// (LSUIElement у project.yml). Вікно відкривається з меню-бару, а
// закриття вікна нічого не гасить — програма працює далі.
//
// Так і має бути. Вона тримає єдиний канал до телефона, тобто мусить
// працювати завжди; іконка в доці лише вдавала б, що її «відкрито», і
// напрошувалась би на ⌘Q.

@main
struct LaserbeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Ключ доступу тут не потрібен: демон пускає без нього все, що
    // прийшло з цього ж компʼютера.
    @StateObject private var client = DaemonClient(
        transport: LocalDaemon.transport(),
        autoStart: true
    )

    var body: some Scene {
        WindowGroup(id: "main") {
            MacRootView(client: client)
                .frame(minWidth: 440, minHeight: 340)
        }
        .defaultSize(width: 520, height: 460)
        .commands {
            CommandGroup(replacing: .newItem) { }   // вікно тут одне
        }

        MenuBarExtra {
            MenuBarContent(client: client)
        } label: {
            Text(client.badge)
        }
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

        // Те саме стосується зʼєднання з телефоном: воно має жити, доки
        // живе програма. Ключ читаємо з демона — він же покаже його в
        // QR-коді, тому пароль в обох місцях завжди той самий.
        //
        // Перечитуємо періодично, бо ключ можуть замінити й повз вікно
        // підключення: викликом /auth/rotate або просто видаленням файла.
        // Тоді слухач лишився б зі старим паролем, і телефон мовчки
        // з'їхав би на запасний шлях. start() нічого не робить, якщо
        // пароль не змінився, тож перевірка майже безкоштовна.
        Task { @MainActor in
            while true {
                PeerServer.shared.start(
                    daemonURL: LocalDaemon.baseURL(),
                    passcode: await LocalDaemon.token(),
                    serviceName: LocalDaemon.serviceName()
                )
                try? await Task.sleep(for: .seconds(60))
            }
        }

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
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

/// Свідомий вихід із програми.
///
/// Демон піднімає програму назад, якщо вона замовкла: вона тримає єдиний
/// канал до телефона, і випадково закрити її не має бути можливо.
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
    static func port() -> Int {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".laserbeak/config.json")

        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int
        else { return 8787 }

        return port
    }

    static func baseURL() -> URL? {
        URL(string: "http://127.0.0.1:\(port())")
    }

    /// Імʼя, під яким ноут видно в мережі.
    ///
    /// Мусить збігатися з тим, що оголошує демон: телефон зводить два
    /// сервіси — прямий канал і HTTP — саме за іменем. Тому читаємо той
    /// самий конфіг, а коли його немає, повторюємо те саме значення за
    /// замовчуванням, що й демон: імʼя вузла без ".local".
    static func serviceName() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".laserbeak/config.json")

        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["serviceName"] as? String, !name.isEmpty {
            return name
        }

        var host = ProcessInfo.processInfo.hostName
        if host.hasSuffix(".local") { host.removeLast(6) }
        return host
    }

    static func transport() -> DaemonTransport? {
        guard let url = baseURL() else { return nil }
        return HTTPTransport(baseURL: url, token: "")
    }

    /// Ключ доступу до демона. Він же пароль зʼєднання з телефоном.
    ///
    /// Питаємо в самого демона, а не читаємо файл: так програма бачить
    /// саме той ключ, яким демон користується просто зараз — зокрема
    /// одразу після заміни ключа.
    static func token() async -> String {
        guard let base = baseURL() else { return "" }

        var request = URLRequest(url: base.appendingPathComponent("auth/token"))
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }

        return object["token"] as? String ?? ""
    }

    /// Замінити ключ. Усі підключені телефони відпадуть, доки не
    /// відсканують новий код.
    static func rotateToken() async -> String {
        guard let base = baseURL() else { return "" }

        var request = URLRequest(url: base.appendingPathComponent("auth/rotate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }

        return object["token"] as? String ?? ""
    }
}
