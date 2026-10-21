import Foundation

// Клієнт демона: опитує /state і публікує стан, а дії відсилає назад.
//
// Демон — єдине джерело істини. Тут нічого не вирішується: програма
// показує те, що прийшло, і передає, що людина натиснула.

@MainActor
final class DaemonClient: ObservableObject {
    @Published private(set) var state: DaemonState?
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    private let http: DaemonHTTP?
    private var pollTask: Task<Void, Never>?
    private let interval: Duration

    /// Скільки опитувань поспіль не вдалося. Одна невдача — ще не обрив:
    /// демон міг саме перезапускатись після правки в src/. Гасимо екран
    /// лише після двох поспіль, тобто чотирьох секунд.
    private var failures = 0

    private static let failuresBeforeOffline = 2

    /// Остання помилка, яку вже записано в лог. Опитування йде кожні дві
    /// секунди, і без цього лежачий демон давав би тридцять рядків на хвилину.
    private var loggedError: String?

    /// Опитування живе, доки живе програма, а не доки відкрите вікно:
    /// інакше меню-бар показував би застиглий стан.
    init(baseURL: URL?, pollEverySeconds: Double = 2) {
        self.http = baseURL.map(DaemonHTTP.init(baseURL:))
        self.interval = .milliseconds(Int(pollEverySeconds * 1000))
        start()
    }

    // ------------------------------------------------------------ опитування

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(2))
            }
        }
    }

    func refresh() async {
        guard let http else {
            isConnected = false
            return
        }

        do {
            let reply = try await http.get("state")
            guard reply.isOK else {
                throw TransportError.broken(reply.errorText ?? "HTTP \(reply.status)")
            }

            state = try JSONDecoder().decode(DaemonState.self, from: reply.data)
            isConnected = true
            failures = 0
            lastError = nil
            if loggedError != nil {
                loggedError = nil
                AppLog.write("звʼязок із демоном відновлено")
            }
        } catch {
            failures += 1
            lastError = error.localizedDescription
            if failures >= Self.failuresBeforeOffline { isConnected = false }

            // Одна невдача — ще не обрив (див. failuresBeforeOffline), а
            // зламаний розбір пишемо одразу: він сам не минеться.
            let text = AppLog.describe(error)
            if (error is DecodingError || failures >= Self.failuresBeforeOffline), text != loggedError {
                loggedError = text
                AppLog.error("GET /state: \(text)")
            }
        }
    }

    /// Примусове оновлення: демон негайно перевіряє, чи живі сесії,
    /// переглядає процеси й дочитує транскрипти — не чекаючи таймерів.
    func forceRefresh() async {
        guard let http, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let reply = try await http.send(method: "POST", path: "refresh", timeout: 20)
            guard reply.isOK else { throw TransportError.broken("HTTP \(reply.status)") }

            state = try JSONDecoder().decode(DaemonState.self, from: reply.data)
            isConnected = true
            failures = 0
            lastError = nil
        } catch {
            await refresh()
        }
    }

    // ------------------------------------------------------------ сесії й проєкти

    /// Своя назва сесії та вимикач її сповіщень. Демон застосовує це у
    /// себе, тож зміна одразу видна всюди — у вікні, в меню-барі, у
    /// розширенні й у самих банерах.
    func saveSession(sid: String, alias: String, notify: Bool) async {
        await act("sessions/settings", ["sid": sid, "alias": alias, "notify": notify])
    }

    /// Колір та іконка проєкту. Порожнє значення — «як типово».
    func saveProject(path: String, color: String, icon: String) async {
        await act("projects/settings", [
            "path": path,
            "settings": ["color": color, "icon": icon],
        ])
    }

    /// Приглушити проєкт: банери його сесій приходять без звуку.
    func setProjectSilent(path: String, silent: Bool) async {
        await act("projects/settings", ["path": path, "settings": ["silent": silent]])
    }

    @discardableResult
    func forgetSession(sid: String) async -> Bool {
        await act("sessions/forget", ["sid": sid])
    }

    /// Режим дозволів: демон тисне Shift+Tab, доки не побачить потрібний.
    @discardableResult
    func setMode(sid: String, mode: String) async -> Bool {
        await act("sessions/mode", ["sid": sid, "mode": mode])
    }

    /// Модель. Claude Code запамʼятовує вибір як типовий для **нових**
    /// сесій — так само, як коли міняєш її руками через /model.
    @discardableResult
    func setModel(sid: String, model: String) async -> Bool {
        await act("sessions/command", ["sid": sid, "model": model])
    }

    /// Рівень зусиль. Теж стає типовим для нових сесій.
    @discardableResult
    func setEffort(sid: String, effort: String) async -> Bool {
        await act("sessions/command", ["sid": sid, "effort": effort])
    }

    /// Стиснути контекст (/compact).
    @discardableResult
    func compact(sid: String) async -> Bool {
        await act("sessions/command", ["sid": sid, "compact": true])
    }

    /// Ctrl-C у сесію: зупинити хід, не закриваючи її.
    @discardableResult
    func interrupt(sid: String) async -> Bool {
        await act("sessions/interrupt", ["sid": sid])
    }

    // ------------------------------------------------------------ налаштування

    func loadSettings() async -> SettingsReply? {
        guard let http, let reply = try? await http.get("settings"), reply.isOK else { return nil }
        return decode(SettingsReply.self, reply.data, from: "settings")
    }

    /// Зберегти частину налаштувань. Демон перевіряє кожне значення й
    /// віддає те, що в нього вийшло, — його й показуємо.
    func saveSettings(_ patch: [String: Any]) async -> SettingsReply? {
        guard let data = await call("settings", patch) else { return nil }
        await refresh()
        return decode(SettingsReply.self, data, from: "settings")
    }

    // ------------------------------------------------------------ оновлення

    func loadUpdate() async -> UpdateDetails? {
        guard let http, let reply = try? await http.get("update"), reply.isOK else { return nil }
        return decode(UpdateReply.self, reply.data, from: "update")?.update
    }

    func checkUpdate() async -> UpdateDetails? {
        guard let data = await call("update/check", [:], timeout: 30) else { return nil }
        await refresh()
        return decode(UpdateReply.self, data, from: "update/check")?.update
    }

    // ------------------------------------------------------------ транспорт

    @discardableResult
    private func act(_ path: String, _ body: [String: Any]) async -> Bool {
        guard let data = await call(path, body) else { return false }
        await refresh()

        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["ok"] as? Bool ?? false
    }

    /// POST і тіло відповіді, якщо демон відповів 200. Інакше — текст
    /// його помилки в lastError: він уже перекладений вибраною мовою.
    private func call(_ path: String, _ body: [String: Any], timeout: TimeInterval = 15) async -> Data? {
        guard let http else { return nil }

        do {
            let reply = try await http.post(path, json: body, timeout: timeout)
            guard reply.isOK else {
                lastError = reply.errorText ?? "HTTP \(reply.status)"
                AppLog.error("дія POST /\(path) → \(reply.status): \(lastError ?? "")")
                return nil
            }
            return reply.data
        } catch {
            lastError = error.localizedDescription
            AppLog.error("дія POST /\(path): \(AppLog.describe(error))")
            return nil
        }
    }

    /// Розбір відповіді, що не валить екран мовчки: якщо поле не те, у
    /// лозі буде, яке саме.
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, from path: String) -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.error("розбір відповіді /\(path): \(AppLog.describe(error))")
            return nil
        }
    }

    // ------------------------------------------------------------ вигляд

    /// Короткий підпис для меню-бару.
    var badge: String {
        guard isConnected, let state else { return "⚠︎" }
        let count = state.sessions.count
        let glyph = state.needsAttentionCount > 0 ? "⏸"
                  : state.workingCount > 0 ? "◐" : "○"
        return count == 0 ? glyph : "\(glyph) \(count)"
    }
}
