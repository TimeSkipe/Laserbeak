import Foundation

// Дзеркало того, що демон віддає на GET /state.
// Ці типи спільні для macOS та iOS — один файл, обидві платформи.
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

// MARK: - Токени

/// Фактичні цифри з транскрипту сесії — не оцінка, а те, що повернув API.
struct TokenUsage: Codable, Hashable {
    var input: Int = 0        // свіжий контекст повз кеш
    var cacheWrite: Int = 0   // запис у кеш
    var cacheRead: Int = 0    // читання з кешу, зазвичай найбільша частина
    var output: Int = 0
    var thinking: Int = 0     // частина output
    var total: Int = 0
    var messages: Int = 0
    var model: String = ""

    var isEmpty: Bool { total == 0 }

    init() {}

    enum CodingKeys: String, CodingKey {
        case input, cacheWrite, cacheRead, output, thinking, total, messages, model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input      = c.value(.input, 0)
        cacheWrite = c.value(.cacheWrite, 0)
        cacheRead  = c.value(.cacheRead, 0)
        output     = c.value(.output, 0)
        thinking   = c.value(.thinking, 0)
        total      = c.value(.total, 0)
        messages   = c.value(.messages, 0)
        model      = c.value(.model, "")
    }
}

// MARK: - Сесія

struct Session: Identifiable, Codable, Hashable {
    var sid: String = ""
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
    // тому на маку й на телефоні видно однакове.
    var alias: String = ""
    var displayName: String = ""
    var notifyEnabled: Bool = true

    // Копиться, доки сесію не закриють остаточно.
    var totalWorkSeconds: Int = 0
    var lastTurnTokens: Int = 0
    var tokens: TokenUsage = TokenUsage()

    /// Сесію запустив сам Laserbeak — вона працює в його терміналі.
    var hosted: Bool = false

    /// У сесію можна писати: або її запустив демон, або вона працює
    /// через tmux у терміналі WebStorm.
    var canInput: Bool = false

    /// Режим дозволів: auto, plan, default, acceptEdits.
    /// Демон читає його з індикатора в самому інтерфейсі Claude Code.
    var permissionMode: String = ""

    /// Рівень зусиль: low, medium, high, xhigh, max.
    /// Читається з тієї ж смужки, що й режим.
    var effort: String = ""

    var id: String { sid }

    var state: SessionStatus { SessionStatus(rawValue: status) ?? .idle }

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
        case sid, label, project, cwd, term, status, since
        case turnStartedAt, lastTurnSeconds, turns, ageSeconds, turnSeconds
        case alias, displayName, notifyEnabled
        case totalWorkSeconds, lastTurnTokens, tokens, hosted, canInput, permissionMode
        case effort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sid              = c.value(.sid, "")
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
        lastTurnTokens   = c.value(.lastTurnTokens, 0)
        tokens           = c.value(.tokens, TokenUsage())
        hosted           = c.value(.hosted, false)
        canInput         = c.value(.canInput, false)
        permissionMode   = c.value(.permissionMode, "")
        effort           = c.value(.effort, "")
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

    var title: String {
        switch self {
        case .opus:   return "Opus 5"
        case .fable:  return "Fable 5"
        case .sonnet: return "Sonnet 5"
        case .haiku:  return "Haiku 4.5"
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

    /// Чи це та модель, яку демон бачить у транскрипті
    /// (там повні назви: claude-opus-5, claude-haiku-4-5-…).
    func matches(_ full: String) -> Bool {
        full.contains(rawValue)
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

    init() {}

    enum CodingKeys: String, CodingKey { case color, icon }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = c.value(.color, "")
        icon  = c.value(.icon, "")
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

// MARK: - Архів переписки

/// Одне повідомлення зі збереженої переписки.
struct ArchivedMessage: Identifiable, Codable, Hashable {
    var ts: Double = 0
    var role: String = ""       // "user" або "assistant"
    var text: String = ""
    var tools: [String] = []
    var uuid: String = ""
    var sidechain: Bool = false

    /// Скільки тривала відповідь на попередню репліку користувача.
    /// Рахує демон і ставить лише на останній відповіді турна.
    var replySeconds: Double?

    var id: String { uuid.isEmpty ? "\(ts)-\(role)-\(text.prefix(16))" : uuid }
    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
    var isUser: Bool { role == "user" }

    init() {}

    /// Повідомлення без тексту, лише з інструментами. Такі показуємо
    /// тонким рядком, а не бульбашкою — інакше стрічка тоне в них.
    var isToolsOnly: Bool { text.isEmpty && !tools.isEmpty }

    enum CodingKeys: String, CodingKey {
        case ts, role, text, tools, uuid, sidechain, replySeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts        = c.value(.ts, 0)
        role      = c.value(.role, "")
        text      = c.value(.text, "")
        tools     = c.value(.tools, [String]())
        uuid      = c.value(.uuid, "")
        sidechain = c.value(.sidechain, false)
        replySeconds = try? c.decodeIfPresent(Double.self, forKey: .replySeconds)
    }
}

struct ArchivedSession: Codable {
    var sid: String = ""
    var label: String = ""
    var project: String = ""
    var messages: Int = 0
    var firstTs: Double = 0
    var lastTs: Double = 0

    init() {}

    enum CodingKeys: String, CodingKey { case sid, label, project, messages, firstTs, lastTs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sid      = c.value(.sid, "")
        label    = c.value(.label, "")
        project  = c.value(.project, "")
        messages = c.value(.messages, 0)
        firstTs  = c.value(.firstTs, 0)
        lastTs   = c.value(.lastTs, 0)
    }
}

struct ArchiveResponse: Codable {
    var ok: Bool = false
    var session: ArchivedSession = ArchivedSession()
    var messages: [ArchivedMessage] = []

    init() {}

    enum CodingKeys: String, CodingKey { case ok, session, messages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok       = c.value(.ok, false)
        session  = c.value(.session, ArchivedSession())
        messages = c.value(.messages, [ArchivedMessage]())
    }
}

// MARK: - Стан демона

/// Адреса компʼютера в локальній мережі — для QR-коду.
struct DaemonAddress: Codable, Hashable, Identifiable {
    var interfaceName: String = ""
    var address: String = ""

    var id: String { address }

    init() {}

    enum CodingKeys: String, CodingKey {
        case interfaceName = "interface"
        case address
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interfaceName = c.value(.interfaceName, "")
        address       = c.value(.address, "")
    }
}

struct DaemonState: Codable {
    var ok: Bool = false
    var uptimeSeconds: Int = 0
    var host: String = ""
    var port: Int = 8787

    /// На чому слухає демон. "127.0.0.1" означає, що запасного шляху по
    /// HTTP немає: телефон дістається лише через програму на маку.
    var bindHost: String = ""

    var addresses: [DaemonAddress] = []
    var projects: [Project] = []
    var sessions: [Session] = []
    var history: [ActivityEvent] = []
    var notifierInstalled: Bool = false

    /// Показуємо лише те, що відкрито просто зараз. Демон памʼятає всі
    /// проєкти — вони знадобляться, коли зʼявляться власні налаштування.
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

    init() {}

    /// Чи відкритий запасний шлях по HTTP у локальній мережі.
    var hasNetworkFallback: Bool { !bindHost.isEmpty && bindHost != "127.0.0.1" }

    enum CodingKeys: String, CodingKey {
        case ok, uptimeSeconds, host, port, bindHost, addresses
        case projects, sessions, history, notifierInstalled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok                = c.value(.ok, false)
        uptimeSeconds     = c.value(.uptimeSeconds, 0)
        host              = c.value(.host, "")
        port              = c.value(.port, 8787)
        bindHost          = c.value(.bindHost, "")
        addresses         = c.value(.addresses, [DaemonAddress]())
        projects          = c.value(.projects, [Project]())
        sessions          = c.value(.sessions, [Session]())
        history           = c.value(.history, [ActivityEvent]())
        notifierInstalled = c.value(.notifierInstalled, false)
    }
}

// MARK: - Форматування

enum Format {
    /// Компактно: 1234 → «1.2k», 3 400 000 → «3.4M»
    static func tokens(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1_000
            return n < 10_000 ? String(format: "%.1fk", k) : String(format: "%.0fk", k)
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    /// Повне число з розділювачами: 38 647 322
    static func tokensFull(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

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
