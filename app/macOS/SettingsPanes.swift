import SwiftUI
import AppKit
import UserNotifications

// Налаштування: загальні, сповіщення, оновлення.
//
// Значення живуть у демона (~/.laserbeak/config.json), тут їх лише
// показують і відсилають назад. Зберігається одразу, без кнопки
// «Зберегти» — як у системних налаштуваннях macOS. Що показати після
// збереження, вирішує відповідь демона, а не те, що ми туди послали.

// MARK: - Загальні

struct GeneralPane: View {
    @ObservedObject var client: DaemonClient

    @State private var reply: SettingsReply?
    @State private var update: UpdateDetails?

    var body: some View {
        Form {
            Section {
                Picker(selection: languageBinding) {
                    (Text(verbatim: "🖥  ") + Text("Як у системі")).tag("auto")
                    Divider()
                    // Назви мов — кожна своєю мовою і з прапором: так їх
                    // упізнають, навіть коли решта вікна незнайомою мовою.
                    ForEach(AppLanguage.names, id: \.code) { language in
                        Text(verbatim: "\(language.flag)  \(language.name)").tag(language.code)
                    }
                } label: {
                    Label("Мова", systemImage: "globe")
                }
                .disabled(reply == nil)

                if AppLanguage.needsRelaunch(daemonLanguage: reply?.language ?? client.state?.language ?? "") {
                    HStack {
                        Label("Вікно перейде на нову мову після перезапуску програми",
                              systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Перезапустити") { AppLanguage.relaunch() }
                    }
                }
            } header: {
                Text("Мова")
            } footer: {
                Text("Одна мова на все: це вікно, меню-бар, банери, історія подій і розширення браузера.")
            }

            Section {
                Picker(selection: islandBinding) {
                    Text("Острів біля вирізу").tag(true)
                    Text("Лише кружок із числом у меню-барі").tag(false)
                } label: {
                    Label("Агенти на екрані", systemImage: "menubar.rectangle")
                }
                .pickerStyle(.radioGroup)
                .disabled(client.state == nil)
            } footer: {
                Text("Острів — знаки агентів обабіч вирізу; помаранчевий — хтось чекає дозволу. На моніторі без вирізу — вузька смужка посеред меню-бару: що робить сесія і скільки триває її хід. Кружок із числом у меню-барі є завжди.")
            }

            Section("Про програму") {
                LabeledContent("Версія") {
                    Text(verbatim: versionText)
                        .monospaced()
                        .textSelection(.enabled)
                }

                LabeledContent("Демон") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(client.isConnected ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(client.isConnected ? String(localized: "працює") : String(localized: "не відповідає"))
                    }
                }

                LabeledContent("Дані й налаштування") {
                    Button("Показати у Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([LocalDaemon.dataDirectory])
                    }
                }

                LabeledContent("Лог демона") {
                    Button("Відкрити") {
                        NSWorkspace.shared.open(LocalDaemon.dataDirectory.appendingPathComponent("daemon.log"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SidebarItem.general.title)
        .task {
            reply = await client.loadSettings()
            update = await client.loadUpdate()
        }
    }

    private var versionText: String {
        guard let update, !update.version.isEmpty else {
            return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        }
        return update.head.isEmpty ? update.title : "\(update.title) · \(update.head)"
    }

    /// Значення бере з /state: острів стежить за ним самим, тож вимикач
    /// діє одразу після збереження.
    private var islandBinding: Binding<Bool> {
        Binding(
            get: { client.state?.islandEnabled ?? true },
            set: { value in
                Task { _ = await client.saveSettings(["island": ["show": value]]) }
            }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { reply?.settings.language ?? "auto" },
            set: { value in
                Task {
                    guard let saved = await client.saveSettings(["language": value]) else { return }
                    reply = saved
                    // Демон перейшов на нову мову одразу; вікну її треба
                    // покласти туди, звідки macOS читає при запуску.
                    AppLanguage.apply(value)
                }
            }
        )
    }
}

// MARK: - Сповіщення

/// Як показати подію, про яку буває банер. Ключі — ті самі, що в
/// config.notify і config.sounds.
struct NotificationKind: Identifiable {
    let id: String

    var title: String {
        switch id {
        case "stop":       return String(localized: "Сесія закінчила роботу")
        case "permission": return String(localized: "Потрібен дозвіл")
        case "idle":       return String(localized: "Нагадування про ввід")
        case "update":     return String(localized: "Нова версія Laserbeak")
        default:           return id
        }
    }

    var hint: String {
        switch id {
        case "stop":       return String(localized: "Claude чи Codex завершили хід і чекають на тебе")
        case "permission": return String(localized: "Агент питає дозволу на дію або схвалення плану")
        case "idle":       return String(localized: "Приблизно за хвилину після відповіді, якщо ти мовчиш. Дублює попереднє")
        case "update":     return String(localized: "На GitHub зʼявилась нова версія")
        default:           return ""
        }
    }

    var symbol: String {
        switch id {
        case "stop":       return "checkmark"
        case "permission": return "hand.raised.fill"
        case "idle":       return "hourglass"
        case "update":     return "arrow.down"
        default:           return "bell.fill"
        }
    }

    var color: Color {
        switch id {
        case "stop":       return .green
        case "permission": return .orange
        case "idle":       return .gray
        case "update":     return .blue
        default:           return .secondary
        }
    }
}

struct NotificationsPane: View {
    @ObservedObject var client: DaemonClient
    @ObservedObject private var notifications = NotificationService.shared

    @State private var reply: SettingsReply?

    var body: some View {
        Form {
            Section {
                if let reply {
                    ForEach(reply.kinds.map(NotificationKind.init(id:))) { kind in
                        KindRow(
                            kind: kind,
                            enabled: binding("notify", \.notify, kind.id, fallback: true),
                            sound: binding("sounds", \.sounds, kind.id, fallback: ""),
                            sounds: reply.sounds
                        )
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("Коли показувати банер")
            } footer: {
                Text("Вимкнути банери однієї сесії можна в її меню: «Назва й сповіщення…». Це сильніше за загальне правило.")
            }

            Section("Система") {
                LabeledContent {
                    if notifications.authorized {
                        Label("дозволено", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Відкрити налаштування сповіщень") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Банери від Laserbeak")
                        if !notifications.authorized {
                            Text("macOS не дозволяє програмі показувати сповіщення")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SidebarItem.notifications.title)
        .task {
            notifications.checkAuthorization()
            reply = await client.loadSettings()
        }
    }

    /// Перемикач чи звук однієї події. Зберігається одразу.
    private func binding<Value>(
        _ group: String,
        _ field: WritableKeyPath<AppSettings, [String: Value]>,
        _ kind: String,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { reply?.settings[keyPath: field][kind] ?? fallback },
            set: { value in
                reply?.settings[keyPath: field][kind] = value
                Task {
                    if let saved = await client.saveSettings([group: [kind: value]]) {
                        reply = saved
                    }
                }
            }
        )
    }
}

private struct KindRow: View {
    let kind: NotificationKind
    @Binding var enabled: Bool
    @Binding var sound: String
    let sounds: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SymbolTile(symbol: kind.symbol, color: kind.color, size: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    Text(kind.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if enabled {
                HStack(spacing: 8) {
                    Picker("Звук", selection: soundPick) {
                        Text("Без звуку").tag("")
                        Divider()
                        // Назви системних звуків macOS не перекладає й сама.
                        ForEach(sounds, id: \.self) { name in
                            Text(verbatim: name).tag(name)
                        }
                    }
                    .frame(maxWidth: 260)

                    Button {
                        play(sound)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(sound.isEmpty)
                    .help("Прослухати")
                }
                .padding(.leading, 42)
            }
        }
        .padding(.vertical, 4)
    }

    /// Вибрав звук — одразу чуєш, який він.
    private var soundPick: Binding<String> {
        Binding(
            get: { sound },
            set: { value in
                sound = value
                play(value)
            }
        )
    }

    private func play(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

// MARK: - Оновлення

/// Чи вийшла нова версія і як її поставити. Ставить людина сама: вікно
/// лише розписує, що виконати, — нічого не перебудовується за спиною.
struct UpdatesPane: View {
    @ObservedObject var client: DaemonClient

    @State private var details: UpdateDetails?
    @State private var busy = false
    @State private var copied = false

    private var summary: UpdateSummary {
        // «Є оновлення» живе і в /state — беремо свіжіше, ніж у разово
        // завантажених деталях.
        client.state?.update ?? details?.summary ?? UpdateSummary()
    }

    var body: some View {
        Form {
            Section {
                hero
            }

            if let details, summary.isAvailable, !details.commands.isEmpty {
                Section {
                    instructions(details)
                } header: {
                    Text("Як оновити")
                }
            }

            if let details, !details.commits.isEmpty, summary.isAvailable {
                Section {
                    ForEach(details.commits) { commit in
                        CommitRow(commit: commit)
                    }
                } header: {
                    Text("Що нового")
                } footer: {
                    if summary.more {
                        Text("Показано не все — повний перелік на GitHub.")
                    }
                }
            }

            Section {
                Toggle(isOn: autoCheck) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Перевіряти автоматично")
                        Text("Раз на шість годин Laserbeak питає GitHub, чи зʼявились нові коміти, і каже банером. Сам нічого не завантажує й не встановлює.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SidebarItem.updates.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Кнопка, а не Link: Link на панелі macOS малює як посилання —
                // синім, у витягнутій капсулі. І є завжди, поки адреси ще
                // немає — лише вимкнена, а не порожнє місце на панелі.
                let url = details.flatMap { URL(string: $0.url) }
                Button {
                    if let url { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Відкрити на GitHub", systemImage: "arrow.up.right")
                }
                .disabled(url == nil)
                .help("Відкрити на GitHub")
            }
        }
        .task { details = await client.loadUpdate() }
        // Нова версія зʼявилась, поки вікно відкрите, — підтягуємо, що в ній.
        .onChange(of: summary.behind) { _, _ in
            Task { details = await client.loadUpdate() }
        }
    }

    // ------------------------------------------------------------ шматки

    private var hero: some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: heroSymbol, color: heroColor, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(heroTitle)
                    .font(.title3.weight(.semibold))
                Text(heroSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                check()
            } label: {
                if busy || details?.checking == true {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Перевірити")
                }
            }
            .controlSize(.large)
            .disabled(busy)
        }
        .padding(.vertical, 6)
    }

    /// Покроково: що виконати і що зробити після.
    private func instructions(_ details: UpdateDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, String(localized: "Онови код і перевстанови Laserbeak у терміналі:"))

            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: details.commands.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    copy(details.commands)
                } label: {
                    Label(copied ? String(localized: "Скопійовано") : String(localized: "Скопіювати"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.leading, 30)

            step(2, String(localized: "Мова й налаштування збережуться: установка бере їх із config.json. Програма перезапуститься сама."))
            step(3, String(localized: "Перезавантаж розширення браузера на сторінці розширень (chrome://extensions або brave://extensions)."))
            step(4, String(localized: "Нові хуки й мод карток діють у нових сесіях Claude Code."))

            Text("Можна й не самому: відкрий цю теку в Claude Code і попроси «Онови Laserbeak» — інструкція для нього є в CLAUDE.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heroSymbol: String {
        switch summary.state {
        case "current":   return "checkmark.seal.fill"
        case "available": return "arrow.down.circle.fill"
        case "ahead":     return "arrow.up.circle.fill"
        case "error":     return "exclamationmark.triangle.fill"
        default:          return "questionmark.circle"
        }
    }

    private var heroColor: Color {
        switch summary.state {
        case "current":   return .green
        case "available": return .blue
        case "ahead":     return .purple
        case "error":     return .orange
        default:          return .gray
        }
    }

    private var heroTitle: String {
        switch summary.state {
        case "current":   return String(localized: "Встановлено найновішу версію")
        case "available": return String(format: String(localized: "Нових змін на GitHub: %@"), summary.behindText)
        case "ahead":     return String(localized: "Ця копія попереду GitHub")
        case "error":     return String(localized: "Не вдалося перевірити")
        default:          return String(localized: "Ще не перевіряли")
        }
    }

    private var heroSubtitle: String {
        if summary.state == "error", let error = details?.error, !error.isEmpty {
            return error
        }
        if summary.state == "ahead" {
            return String(localized: "Тут є коміти, яких на GitHub ще немає — оновлювати нічого.")
        }

        var parts: [String] = []
        if let details, !details.version.isEmpty {
            parts.append(details.head.isEmpty ? details.title : "\(details.title) · \(details.head)")
        }
        if summary.checkedAt > 0 {
            let when = Date(timeIntervalSince1970: summary.checkedAt / 1000)
            parts.append(String(format: String(localized: "перевірено %@"),
                                when.formatted(.relative(presentation: .named))))
        }
        return parts.joined(separator: " · ")
    }

    private var autoCheck: Binding<Bool> {
        Binding(
            get: { details?.enabled ?? true },
            set: { value in
                details?.enabled = value
                Task {
                    _ = await client.saveSettings(["updates": ["check": value]])
                    details = await client.loadUpdate()
                }
            }
        )
    }

    // ------------------------------------------------------------ дії

    private func check() {
        busy = true
        Task {
            if let fresh = await client.checkUpdate() { details = fresh }
            busy = false
        }
    }

    /// Команди одним блоком, кожна з нового рядка — вставив у термінал, і
    /// вони пішли по черзі.
    private func copy(_ commands: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands.joined(separator: "\n") + "\n", forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct CommitRow: View {
    let commit: UpdateCommit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: commit.sha)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: commit.message)
                    .lineLimit(2)
                if let when = commit.when {
                    Text(when, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if let url = URL(string: commit.url), !commit.url.isEmpty {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right")
                }
                .help("Відкрити на GitHub")
            }
        }
    }
}
