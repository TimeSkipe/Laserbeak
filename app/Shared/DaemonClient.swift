import Foundation

// Клієнт демона: опитує /state і публікує стан.
//
// Сам він не знає, яким шляхом ідуть дані. На маку це HTTP на 127.0.0.1,
// на телефоні — зашифроване зʼєднання прямо з маком, а якщо воно не
// склалось, то HTTP по Wi-Fi із ключем. Усе це ховається за
// DaemonTransport, тому екрани однакові на обох платформах.

@MainActor
final class DaemonClient: ObservableObject {
    @Published private(set) var state: DaemonState?
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    /// Ключ не підійшов. Окремо від lastError, бо лікується це не
    /// «спробуй ще раз», а «відскануй код на маку заново».
    @Published private(set) var needsPairing = false

    /// Куди ми зараз ходимо — для смужки стану.
    @Published private(set) var target = ""

    private var transport: DaemonTransport?
    private var pollTask: Task<Void, Never>?
    private let interval: Duration

    /// Скільки опитувань поспіль не вдалося.
    ///
    /// Одна невдача — ще не обрив. Прямий канал живе довго й на ньому
    /// трапляється всяке: телефон прокинувся, мак поспав, кадр не
    /// дійшов. Наступний запит підніме зʼєднання наново й усе поїде
    /// далі, тому гасити екран через один невдалий такт — це блимання
    /// на рівному місці. Чекаємо двох поспіль, тобто чотирьох секунд.
    private var failures = 0

    private static let failuresBeforeOffline = 2

    /// `autoStart` потрібен маку: там опитування має жити, доки живе програма,
    /// а не доки відкрите вікно. Інакше після закриття вікна меню-бар
    /// показував би застиглий стан.
    init(transport: DaemonTransport? = nil, pollEverySeconds: Double = 2, autoStart: Bool = false) {
        self.transport = transport
        self.target = transport?.describeTarget ?? ""
        self.interval = .milliseconds(Int(pollEverySeconds * 1000))
        if autoStart { start() }
    }

    /// Перемкнутись на інший шлях до демона. Старий стан скидається:
    /// показувати чужі проєкти, доки не прийшли свої, — гірше за порожньо.
    func use(_ transport: DaemonTransport?) {
        (self.transport as? PeerTransport)?.disconnect()

        self.transport = transport
        self.target = transport?.describeTarget ?? ""
        state = nil
        isConnected = false
        lastError = nil
        needsPairing = false
        failures = 0
    }

    var hasTransport: Bool { transport != nil }

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

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let transport else {
            isConnected = false
            failures = 0
            return
        }

        do {
            let reply = try await transport.get("state", timeout: 5)

            if reply.isUnauthorized {
                // А це вже певна відповідь, а не мовчання: чекати
                // другого разу нема сенсу.
                needsPairing = true
                isConnected = false
                failures = 0
                lastError = String(localized: "ключ доступу не підійшов")
                return
            }

            guard reply.isOK else { throw TransportError.broken("демон відповів \(reply.status)") }

            state = try JSONDecoder().decode(DaemonState.self, from: reply.data)
            isConnected = true
            failures = 0
            lastError = nil
            needsPairing = false
        } catch {
            failures += 1
            lastError = error.localizedDescription
            if failures >= Self.failuresBeforeOffline { isConnected = false }
        }
    }

    /// Примусове оновлення: демон негайно перевіряє, чи живі сесії,
    /// переглядає процеси й дочитує переписку — не чекаючи таймерів.
    func forceRefresh() async {
        guard let transport, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let reply = try await transport.send(
                method: "POST", path: "refresh", query: [], body: nil, timeout: 20
            )
            guard reply.isOK else { throw TransportError.broken("демон відповів \(reply.status)") }

            state = try JSONDecoder().decode(DaemonState.self, from: reply.data)
            isConnected = true
            failures = 0
            lastError = nil
        } catch {
            // Не вдалося — лишаємось на звичайному опитуванні.
            await refresh()
        }
    }

    // ------------------------------------------------------------ дії

    /// Зберегти свою назву сесії та вимикач її сповіщень.
    /// Демон застосовує це у себе, тому зміна одразу видна всюди —
    /// у вікні, в меню-барі, на телефоні і в самих банерах.
    func saveSession(sid: String, alias: String, notify: Bool) async {
        await act("sessions/settings", ["sid": sid, "alias": alias, "notify": notify])
    }

    /// Зберегти колір та іконку проєкту. Порожнє значення означає
    /// «як типово» і прибирає налаштування.
    func saveProject(path: String, color: String, icon: String) async {
        await act("projects/settings", [
            "path": path,
            "settings": ["color": color, "icon": icon],
        ])
    }

    /// Написати в сесію так, ніби текст набрали з клавіатури.
    @discardableResult
    func sendInput(sid: String, text: String) async -> Bool {
        await act("sessions/input", ["sid": sid, "text": text])
    }

    /// Запустити нову сесію Claude Code у проєкті.
    /// Демон приймає це лише з самого мака: це єдина дія, що створює
    /// на компʼютері щось нове.
    @discardableResult
    func spawnSession(projectPath: String, label: String, prompt: String = "") async -> Bool {
        await act("sessions/spawn", [
            "projectPath": projectPath,
            "label": label,
            "prompt": prompt,
        ])
    }

    /// Прибрати сесію зі списку вручну.
    @discardableResult
    func forgetSession(sid: String) async -> Bool {
        await act("sessions/forget", ["sid": sid])
    }

    /// Перемкнути режим дозволів сесії.
    @discardableResult
    func setMode(sid: String, mode: String) async -> Bool {
        await act("sessions/mode", ["sid": sid, "mode": mode])
    }

    /// Змінити модель.
    ///
    /// Увага: Claude Code запамʼятовує вибір як типовий для **нових**
    /// сесій — так само, як коли міняєш модель руками через /model.
    @discardableResult
    func setModel(sid: String, model: String) async -> Bool {
        await act("sessions/command", ["sid": sid, "model": model])
    }

    /// Змінити рівень зусиль. Теж стає типовим для нових сесій.
    @discardableResult
    func setEffort(sid: String, effort: String) async -> Bool {
        await act("sessions/command", ["sid": sid, "effort": effort])
    }

    /// Стиснути контекст сесії (/compact).
    @discardableResult
    func compact(sid: String) async -> Bool {
        await act("sessions/command", ["sid": sid, "compact": true])
    }

    /// Збережена переписка сесії.
    func loadHistory(sid: String, limit: Int = 0) async -> ArchiveResponse? {
        guard let transport else { return nil }

        let query = limit > 0 ? [URLQueryItem(name: "limit", value: String(limit))] : []

        guard let reply = try? await transport.get("archive/\(sid)", query: query, timeout: 20),
              reply.isOK
        else { return nil }

        return try? JSONDecoder().decode(ArchiveResponse.self, from: reply.data)
    }

    @discardableResult
    private func act(_ path: String, _ body: [String: Any]) async -> Bool {
        guard let transport else { return false }

        guard let reply = try? await transport.post(path, json: body) else { return false }

        if reply.isUnauthorized {
            needsPairing = true
            return false
        }

        await refresh()

        guard reply.isOK,
              let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
        else { return false }

        return object["ok"] as? Bool ?? false
    }

    // ------------------------------------------------------------ вигляд

    /// Короткий підпис для меню-бару / заголовка.
    var badge: String {
        guard isConnected, let state else { return "⚠︎" }
        let count = state.sessions.count
        let glyph = state.needsAttentionCount > 0 ? "⏸"
                  : state.workingCount > 0 ? "◐" : "○"
        return count == 0 ? glyph : "\(glyph) \(count)"
    }
}
