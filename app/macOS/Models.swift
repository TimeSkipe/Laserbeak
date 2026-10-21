import Foundation

// Дзеркало того, що демон віддає на GET /state, /settings і /update.
//
// ВАЖЛИВО про розбір JSON.
//
// Swift НЕ підставляє значення за замовчуванням, коли ключа немає у
// відповіді: синтезований декодер кидає keyNotFound, і тоді валиться
// розбір усього /state — програма показує порожній екран.
//
// Демон розвивається швидше за клієнта, тому кожна нова властивість
// інакше означала б розбитий інтерфейс до перезбірки програми. Щоб
// цього не ставалось, моделі розбираються вручну через decodeIfPresent:
// відсутнє поле стає значенням за замовчуванням, решта даних працює.

/// Дрібний помічник, щоб не повторювати decodeIfPresent ?? default.
private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        // try? згортає два рівні опціональності в один, тому одного ?? досить:
        // немає ключа або тип не збігся — беремо значення за замовчуванням.
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - Статуси

enum SessionStatus: String, Codable {
    case idle
    case working
    case waiting
    case needsInput = "needs-input"

    var title: String {
        switch self {
        case .idle:       return String(localized: "простій")
        case .working:    return String(localized: "працює")
        case .waiting:    return String(localized: "закінчив")
        case .needsInput: return String(localized: "чекає на дозвіл")
        }
    }

    var symbol: String {
        switch self {
        case .idle:       return "circle"
        case .working:    return "circle.dotted"
        case .waiting:    return "checkmark.circle.fill"
        case .needsInput: return "pause.circle.fill"
        }
    }

    /// Порядок сортування: спершу те, що вимагає уваги.
    var urgency: Int {
        switch self {
        case .needsInput: return 0
        case .waiting:    return 1
        case .working:    return 2
        case .idle:       return 3
        }
    }
}

/// Статус проєкту — це статус найтерміновішої з його сесій.
/// `offline` означає, що проєкт відомий, але зараз у ньому нікого немає.
enum ProjectStatus: String, Codable {
    case needsInput = "needs-input"
    case waiting
    case working
    case idle
    case offline

    var title: String {
        switch self {
        case .needsInput: return String(localized: "чекає на дозвіл")
        case .waiting:    return String(localized: "закінчив")
        case .working:    return String(localized: "працює")
        case .idle:       return String(localized: "простій")
        case .offline:    return String(localized: "немає сесій")
        }
    }

    var order: Int {
        switch self {
        case .needsInput: return 0
        case .waiting:    return 1
        case .working:    return 2
        case .idle:       return 3
        case .offline:    return 4
        }
    }
}

// MARK: - Сесія

struct Session: Identifiable, Codable, Hashable {
    var sid: String = ""
    /// claude або codex. Те, що вміє лише Claude Code (режими, модель,
    /// зусилля), для Codex не показуємо — демон однаково відмовить.
    var agent: String = "claude"
    var label: String = ""
    var project: String = ""
    var cwd: String = ""
    var term: String = ""
    var status: String = "idle"
    var since: Double = 0            // epoch ms
    var turnStartedAt: Double?
    var lastTurnSeconds: Double?
    var turns: Int = 0
    var ageSeconds: Int = 0
    var turnSeconds: Int?

    // Своя назва та вимикач сповіщень приходять уже застосованими з демона,
    // тому у вікні, в меню-барі й у банерах видно однакове.
    var alias: String = ""
    var displayName: String = ""
    var notifyEnabled: Bool = true

    // Копиться, доки сесію не закриють остаточно.
    var totalWorkSeconds: Int = 0

    /// Сесію запустив сам Laserbeak — вона працює в його терміналі.
    var hosted: Bool = false

    /// У сесію можна передати клавіші: перемкнути режим, модель, стиснути
    /// контекст. Можна, коли вона працює через tmux (`start`) або її
    /// запустив демон.
    var canInput: Bool = false

    /// Режим дозволів: auto, plan, default, acceptEdits.
    /// Демон читає його з індикатора в самому інтерфейсі Claude Code.
    var permissionMode: String = ""

    /// Рівень зусиль: low, medium, high, xhigh, max.
    /// Демон бере його з ~/.claude/settings.json.
    var effort: String = ""

    /// Що сесія робить у цьому ході: «редагує server.js». Демон бере
    /// останній виклик інструмента з транскрипту; між ходами — nil.
    var activity: SessionActivity?

    /// Скільки памʼяті тримає агент разом із тим, що він запустив
    /// (MCP-сервери, браузер). Демон рахує з таблиці процесів; nil — процес
    /// сесії невідомий.
    var memory: SessionMemory?

    /// Памʼять словами системи: «1,6 ГБ».
    var memoryText: String? {
        memory.map { ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .memory) }
    }

    var id: String { sid }

    var state: SessionStatus { SessionStatus(rawValue: status) ?? .idle }

    var isCodex: Bool { agent == "codex" }

    /// Що показувати користувачу. displayName рахує демон; якщо його раптом
    /// немає — падаємо назад на мітку з CLAUDE_LABEL.
    var title: String { displayName.isEmpty ? label : displayName }

    /// Скільки триває поточний турн, або скільки тривав попередній.
    var durationText: String? {
        if let t = turnSeconds { return Format.duration(Double(t)) }
        if let t = lastTurnSeconds { return Format.duration(t) }
        return nil
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case sid, agent, label, project, cwd, term, status, since
        case turnStartedAt, lastTurnSeconds, turns, ageSeconds, turnSeconds
        case alias, displayName, notifyEnabled
        case totalWorkSeconds, hosted, canInput, permissionMode
        case effort, activity, memory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sid              = c.value(.sid, "")
        agent            = c.value(.agent, "claude")
        label            = c.value(.label, "")
        project          = c.value(.project, "")
        cwd              = c.value(.cwd, "")
        term             = c.value(.term, "")
        status           = c.value(.status, "idle")
        since            = c.value(.since, 0)
        turnStartedAt    = try? c.decodeIfPresent(Double.self, forKey: .turnStartedAt)
        lastTurnSeconds  = try? c.decodeIfPresent(Double.self, forKey: .lastTurnSeconds)
        turns            = c.value(.turns, 0)
        ageSeconds       = c.value(.ageSeconds, 0)
        turnSeconds      = try? c.decodeIfPresent(Int.self, forKey: .turnSeconds)
        alias            = c.value(.alias, "")
        displayName      = c.value(.displayName, "")
        notifyEnabled    = c.value(.notifyEnabled, true)
        totalWorkSeconds = c.value(.totalWorkSeconds, 0)
        hosted           = c.value(.hosted, false)
        canInput         = c.value(.canInput, false)
        permissionMode   = c.value(.permissionMode, "")
        effort           = c.value(.effort, "")
        activity         = try? c.decodeIfPresent(SessionActivity.self, forKey: .activity)
        memory           = try? c.decodeIfPresent(SessionMemory.self, forKey: .memory)
    }
}

struct SessionMemory: Codable, Hashable {
    var bytes: Double = 0
    var processes: Int = 0

    enum CodingKeys: String, CodingKey { case bytes, processes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytes     = c.value(.bytes, 0)
        processes = c.value(.processes, 0)
    }
}

/// Остання дія сесії — вже словами вибраної мови.
struct SessionActivity: Codable, Hashable {
    var kind: String = ""
    var text: String = ""
    var at: Double = 0

    enum CodingKeys: String, CodingKey { case kind, text, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, "")
        text = c.value(.text, "")
        at   = c.value(.at, 0)
    }
}

/// Рівні зусиль Claude Code, від найдешевшого до найдорожчого.
enum EffortLevel: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:    return String(localized: "низькі")
        case .medium: return String(localized: "середні")
        case .high:   return String(localized: "високі")
        case .xhigh:  return String(localized: "дуже високі")
        case .max:    return String(localized: "максимальні")
        }
    }

    var hint: String {
        switch self {
        case .low:    return String(localized: "швидко й прямолінійно")
        case .medium: return String(localized: "розумний баланс")
        case .high:   return String(localized: "думає ретельніше")
        case .xhigh:  return String(localized: "для складного")
        case .max:    return String(localized: "найдовше й найдорожче")
        }
    }
}

/// Моделі, які приймає команда /model. Назви мають збігатися зі списком
/// у демоні (src/server.js) — саме він вирішує, що дозволено.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case opus, fable, sonnet, haiku

    var id: String { rawValue }

    // Без номера версії: /model opus завжди бере найсвіжіший Opus, і
    // цифра в меню застаріла б з першим же релізом.
    var title: String {
        switch self {
        case .opus:   return "Opus"
        case .fable:  return "Fable"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        }
    }

    var hint: String {
        switch self {
        case .opus:   return String(localized: "щодня і для складного")
        case .fable:  return String(localized: "найважче й найдовше")
        case .sonnet: return String(localized: "швидко, для рутини")
        case .haiku:  return String(localized: "найшвидша, для дрібниць")
        }
    }
}

/// Режими дозволів Claude Code, у порядку показу.
enum PermissionMode: String, CaseIterable, Identifiable {
    case auto
    case plan
    case acceptEdits
    case `default`

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:        return String(localized: "авто")
        case .plan:        return String(localized: "планування")
        case .acceptEdits: return String(localized: "правки без питань")
        case .default:     return String(localized: "звичайний")
        }
    }

    var symbol: String {
        switch self {
        case .auto:        return "bolt"
        case .plan:        return "list.bullet.clipboard"
        case .acceptEdits: return "square.and.pencil"
        case .default:     return "hand.raised"
        }
    }

    /// Що саме означає режим — показуємо підказкою при виборі.
    var hint: String {
        switch self {
        case .auto:        return String(localized: "Claude сам вирішує, що безпечно виконати")
        case .plan:        return String(localized: "спершу план, дії лише після схвалення")
        case .acceptEdits: return String(localized: "правки файлів без запитів")
        case .default:     return String(localized: "питає дозвіл на кожну дію")
        }
    }
}

// MARK: - Проєкт

/// Те, що користувач налаштував для проєкту вручну.
/// Зберігається демоном у projects.json і переживає все.
struct ProjectSettings: Codable, Hashable {
    var color: String = ""   // назва з палітри, порожнє = за статусом
    var icon: String = ""    // назва іконки Lucide, порожнє = типова
    var silent: Bool = false // банери сесій цього проєкту — без звуку

    init() {}

    enum CodingKeys: String, CodingKey { case color, icon, silent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color  = c.value(.color, "")
        icon   = c.value(.icon, "")
        silent = c.value(.silent, false)
    }
}

struct Project: Identifiable, Codable, Hashable {
    var path: String = ""
    var name: String = ""
    var firstSeen: Double = 0
    var lastSeen: Double = 0
    var editorBundleId: String = ""
    var status: String = "offline"
    var sessionCount: Int = 0
    var sessions: [Session] = []

    // Побачене прямо в системі, повз хуки: відкриті вкладки термінала
    // і живі процеси Claude.
    var terminals: Int = 0
    var claudeTerminals: Int = 0
    var plainTerminals: Int = 0
    var claudeProcesses: Int = 0
    var untracked: Int = 0
    var discovered: Bool = false

    /// Відкритий в IDE прямо зараз, або має живі вкладки чи сесії.
    /// Закриті проєкти лишаються в реєстрі демона — просто не в списку.
    var isOpen: Bool = false

    var settings: ProjectSettings = ProjectSettings()

    var id: String { path }

    /// Іконка проєкту: обрана користувачем або типова.
    var iconName: String {
        settings.icon.isEmpty ? Lucide.fallback : settings.icon
    }
    var state: ProjectStatus { ProjectStatus(rawValue: status) ?? .offline }
    var isLive: Bool { sessionCount > 0 }
    var displayName: String { name }

    var sessionCountText: String {
        switch sessionCount {
        case 0: return String(localized: "немає сесій")
        case 1: return String(localized: "1 сесія")
        case 2...4: return String(format: String(localized: "%d сесії"), sessionCount)
        default: return String(format: String(localized: "%d сесій"), sessionCount)
        }
    }

    /// Коротко про відкриті вкладки: скільки з Claude, скільки порожніх.
    var terminalsText: String? {
        guard terminals > 0 else { return nil }

        var parts: [String] = []
        if claudeTerminals > 0 { parts.append(String(format: String(localized: "%d з Claude"), claudeTerminals)) }
        if plainTerminals > 0 { parts.append(String(format: String(localized: "%d без"), plainTerminals)) }

        let tail = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return "\(terminals) \(Project.tabWord(terminals))\(tail)"
    }

    static func tabWord(_ n: Int) -> String {
        switch n {
        case 1: return String(localized: "вкладка")
        case 2...4: return String(localized: "вкладки")
        default: return String(localized: "вкладок")
        }
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case path, name, firstSeen, lastSeen, editorBundleId, status
        case sessionCount, sessions
        case terminals, claudeTerminals, plainTerminals, claudeProcesses
        case untracked, discovered, isOpen, settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path            = c.value(.path, "")
        name            = c.value(.name, "")
        firstSeen       = c.value(.firstSeen, 0)
        lastSeen        = c.value(.lastSeen, 0)
        editorBundleId  = c.value(.editorBundleId, "")
        status          = c.value(.status, "offline")
        sessionCount    = c.value(.sessionCount, 0)
        sessions        = c.value(.sessions, [Session]())
        terminals       = c.value(.terminals, 0)
        claudeTerminals = c.value(.claudeTerminals, 0)
        plainTerminals  = c.value(.plainTerminals, 0)
        claudeProcesses = c.value(.claudeProcesses, 0)
        untracked       = c.value(.untracked, 0)
        discovered      = c.value(.discovered, false)
        isOpen          = c.value(.isOpen, false)
        settings        = c.value(.settings, ProjectSettings())
    }
}

// MARK: - Подія

struct ActivityEvent: Identifiable, Codable, Hashable {
    var ts: Double = 0               // epoch ms
    var sid: String = ""
    var label: String = ""
    var project: String = ""
    var kind: String = ""
    var message: String = ""
    var seconds: Double?

    var id: String { "\(ts)-\(sid)-\(kind)" }
    var date: Date { Date(timeIntervalSince1970: ts / 1000) }

    init() {}

    enum CodingKeys: String, CodingKey {
        case ts, sid, label, project, kind, message, seconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts      = c.value(.ts, 0)
        sid     = c.value(.sid, "")
        label   = c.value(.label, "")
        project = c.value(.project, "")
        kind    = c.value(.kind, "")
        message = c.value(.message, "")
        seconds = try? c.decodeIfPresent(Double.self, forKey: .seconds)
    }
}

// MARK: - Стан демона

struct DaemonState: Codable {
    var ok: Bool = false
    var uptimeSeconds: Int = 0
    var host: String = ""
    var port: Int = 8787

    /// Мова, якою говорить демон, — уже розвʼязана з "auto". Нею ж має
    /// говорити й вікно: якщо ні, мову змінили, поки програма працювала.
    var language: String = ""

    /// Чи є на GitHub новіша версія.
    var update: UpdateSummary = UpdateSummary()

    var projects: [Project] = []
    var sessions: [Session] = []
    var history: [ActivityEvent] = []
    var notifierInstalled: Bool = false

    /// Чи показувати острів біля вирізу (config.json → island.show).
    var islandEnabled: Bool = true

    /// Показуємо лише те, що відкрито просто зараз. Демон памʼятає всі
    /// проєкти разом із їхніми кольорами й іконками.
    ///
    /// Порядок: спершу ті, що чекають на тебе, потім активні, потім решта
    /// за свіжістю.
    var sortedProjects: [Project] {
        projects
            .filter(\.isOpen)
            .sorted {
                $0.state.order != $1.state.order
                    ? $0.state.order < $1.state.order
                    : $0.lastSeen > $1.lastSeen
            }
    }

    /// Усі відомі проєкти, включно із закритими.
    var allProjects: [Project] {
        projects.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Сесії, відсортовані за терміновістю: те, що чекає на тебе — угорі.
    var sortedSessions: [Session] {
        sessions.sorted {
            $0.state.urgency != $1.state.urgency
                ? $0.state.urgency < $1.state.urgency
                : $0.since < $1.since
        }
    }

    var needsAttentionCount: Int {
        sessions.filter { $0.state == .needsInput }.count
    }

    var workingCount: Int {
        sessions.filter { $0.state == .working }.count
    }

    var waitingCount: Int {
        sessions.filter { $0.state == .waiting }.count
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case ok, uptimeSeconds, host, port, language, update
        case projects, sessions, history, notifierInstalled
    }
    // Окремо від CodingKeys: там лише поля, які кодуються як є.
    enum ExtraKeys: String, CodingKey { case island }
    enum IslandKeys: String, CodingKey { case show }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok                = c.value(.ok, false)
        uptimeSeconds     = c.value(.uptimeSeconds, 0)
        host              = c.value(.host, "")
        port              = c.value(.port, 8787)
        language          = c.value(.language, "")
        update            = c.value(.update, UpdateSummary())
        projects          = c.value(.projects, [Project]())
        sessions          = c.value(.sessions, [Session]())
        history           = c.value(.history, [ActivityEvent]())
        notifierInstalled = c.value(.notifierInstalled, false)
        let extra = try? decoder.container(keyedBy: ExtraKeys.self)
        let island = try? extra?.nestedContainer(keyedBy: IslandKeys.self, forKey: .island)
        islandEnabled     = island?.value(.show, true) ?? true
    }
}

// MARK: - Оновлення

/// Коротко — те, що приходить у кожному /state.
struct UpdateSummary: Codable, Hashable {
    /// unknown | current | available | ahead | error
    var state: String = "unknown"
    var behind: Int = 0
    /// Нових комітів більше, ніж демон бачив у списку.
    var more: Bool = false
    var checkedAt: Double = 0

    var isAvailable: Bool { state == "available" }

    /// «3» або «50+».
    var behindText: String { more ? "\(behind)+" : "\(behind)" }

    init() {}

    enum CodingKeys: String, CodingKey { case state, behind, more, checkedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state     = c.value(.state, "unknown")
        behind    = c.value(.behind, 0)
        more      = c.value(.more, false)
        checkedAt = c.value(.checkedAt, 0)
    }
}

struct UpdateCommit: Codable, Hashable, Identifiable {
    var sha: String = ""
    var message: String = ""
    var date: String = ""
    var url: String = ""

    var id: String { sha }

    var when: Date? { ISO8601DateFormatter().date(from: date) }

    init() {}

    enum CodingKeys: String, CodingKey { case sha, message, date, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha     = c.value(.sha, "")
        message = c.value(.message, "")
        date    = c.value(.date, "")
        url     = c.value(.url, "")
    }
}

/// Повністю — для розділу «Оновлення».
struct UpdateDetails: Codable, Hashable {
    var summary = UpdateSummary()
    var enabled: Bool = true
    var checking: Bool = false
    var version: String = ""
    /// Назва релізу для людини: «White Album 1.0». Порожнє — старий демон.
    var release: String = ""
    var head: String = ""
    var url: String = ""
    var error: String = ""
    var commits: [UpdateCommit] = []
    /// Звідки встановлено Laserbeak і що там виконати, щоб оновитись.
    var root: String = ""
    var commands: [String] = []

    init() {}

    /// Що показати як версію: назву релізу, а без неї — номер.
    var title: String { release.isEmpty ? version : release }

    enum CodingKeys: String, CodingKey {
        case enabled, checking, version, release, head, url, error, commits
        case root, commands
    }

    init(from decoder: Decoder) throws {
        // Ті самі поля, що й у короткому вигляді, лежать на тому ж рівні.
        summary = (try? UpdateSummary(from: decoder)) ?? UpdateSummary()

        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled           = c.value(.enabled, true)
        checking          = c.value(.checking, false)
        version           = c.value(.version, "")
        release           = c.value(.release, "")
        head              = c.value(.head, "")
        url               = c.value(.url, "")
        error             = c.value(.error, "")
        commits           = c.value(.commits, [UpdateCommit]())
        root              = c.value(.root, "")
        commands          = c.value(.commands, [String]())
    }

    func encode(to encoder: Encoder) throws {}
}

struct UpdateReply: Decodable {
    var update = UpdateDetails()

    enum CodingKeys: String, CodingKey { case update }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        update = c.value(.update, UpdateDetails())
    }
}

// MARK: - Налаштування

/// Загальні налаштування — те, що лежить у config.json і міняється з вікна.
struct AppSettings: Codable, Hashable {
    var language: String = "auto"
    var notify: [String: Bool] = [:]
    var sounds: [String: String] = [:]
    var checkUpdates: Bool = true

    init() {}

    enum CodingKeys: String, CodingKey { case language, notify, sounds, updates }
    enum UpdatesKeys: String, CodingKey { case check }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = c.value(.language, "auto")
        notify   = c.value(.notify, [String: Bool]())
        sounds   = c.value(.sounds, [String: String]())
        let updates = try? c.nestedContainer(keyedBy: UpdatesKeys.self, forKey: .updates)
        checkUpdates = updates?.value(.check, true) ?? true
    }

    func encode(to encoder: Encoder) throws {}
}

/// Відповідь /settings: значення плюс те, з чого дозволено вибирати.
struct SettingsReply: Decodable {
    var settings = AppSettings()
    /// Мова, якою все говорить просто зараз, з урахуванням "auto".
    var language: String = ""
    var languages: [String] = []
    var kinds: [String] = []
    var sounds: [String] = []

    enum CodingKeys: String, CodingKey { case settings, language, languages, kinds, sounds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings  = c.value(.settings, AppSettings())
        language  = c.value(.language, "")
        languages = c.value(.languages, [String]())
        kinds     = c.value(.kinds, [String]())
        sounds    = c.value(.sounds, [String]())
    }
}

// MARK: - Форматування

enum Format {
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: String(localized: "%dс"), Int(seconds.rounded())) }
        let m = Int(seconds) / 60
        if m < 60 { return String(format: String(localized: "%dхв %dс"), m, Int(seconds) % 60) }
        return String(format: String(localized: "%dгод %dхв"), m / 60, m % 60)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
