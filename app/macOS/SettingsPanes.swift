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
        return update.head.isEmpty ? update.version : "\(update.version) · \(update.head)"
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
        case "update":     return String(localized: "На GitHub є нові зміни, або оновлення завершилось")
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

struct UpdatesPane: View {
    @ObservedObject var client: DaemonClient

    @State private var details: UpdateDetails?
    @State private var busy = false
    @State private var confirmInstall = false

    private var summary: UpdateSummary {
        // Стан установки й «є оновлення» живуть і в /state — беремо
        // свіжіше, ніж у разово завантажених деталях.
        client.state?.update ?? details?.summary ?? UpdateSummary()
    }

    var body: some View {
        Form {
            Section {
                hero
            }

            if let details, summary.install == "done" || summary.install == "failed" {
                Section("Останнє оновлення") {
                    lastInstall(details)
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
                        Text("Раз на шість годин Laserbeak питає GitHub, чи зʼявились нові коміти, і каже банером. Нічого не завантажує, доки не натиснеш «Оновити».")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } footer: {
                Text("Оновлення — це git pull у теці, звідки Laserbeak встановлено, і повна установка: демон, хуки, програма. Розширення браузера після цього треба перезавантажити на сторінці розширень.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SidebarItem.updates.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let url = details.flatMap({ URL(string: $0.url) }) {
                    Link(destination: url) {
                        Label("Відкрити на GitHub", systemImage: "arrow.up.right.square")
                    }
                    .help("Відкрити на GitHub")
                }
            }
        }
        .task { details = await client.loadUpdate() }
        // Установка закінчилась — підтягуємо подробиці: на чому впала чи
        // до якого коміту оновилось.
        .onChange(of: summary.install) { _, _ in
            Task { details = await client.loadUpdate() }
        }
        .confirmationDialog(
            String(localized: "Оновити Laserbeak?"),
            isPresented: $confirmInstall,
            titleVisibility: .visible
        ) {
            Button("Оновити") { install() }
            Button("Скасувати", role: .cancel) { }
        } message: {
            Text("Laserbeak зробить git pull і перезбере себе. Це хвилина-дві; програма перезапуститься у меню-барі, а результат скаже банер.")
        }
    }

    // ------------------------------------------------------------ шматки

    private var hero: some View {
        HStack(spacing: 14) {
            if summary.isInstalling {
                ProgressView()
                    .frame(width: 46, height: 46)
            } else {
                SymbolTile(symbol: heroSymbol, color: heroColor, size: 46)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(heroTitle)
                    .font(.title3.weight(.semibold))
                Text(heroSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if summary.isAvailable && !summary.isInstalling {
                Button("Оновити") { confirmInstall = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

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
            .disabled(busy || summary.isInstalling)
        }
        .padding(.vertical, 6)
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
        if summary.isInstalling { return String(localized: "Оновлюю…") }
        switch summary.state {
        case "current":   return String(localized: "Встановлено найновішу версію")
        case "available": return String(format: String(localized: "Нових змін на GitHub: %@"), summary.behindText)
        case "ahead":     return String(localized: "Ця копія попереду GitHub")
        case "error":     return String(localized: "Не вдалося перевірити")
        default:          return String(localized: "Ще не перевіряли")
        }
    }

    private var heroSubtitle: String {
        if summary.isInstalling {
            return String(localized: "git pull і перезбірка — хвилина-дві. Програма перезапуститься сама.")
        }
        if summary.state == "error", let error = details?.error, !error.isEmpty {
            return error
        }
        if summary.state == "ahead" {
            return String(localized: "Тут є коміти, яких на GitHub ще немає — оновлювати нічого.")
        }

        var parts: [String] = []
        if let details, !details.version.isEmpty {
            parts.append(details.head.isEmpty ? details.version : "\(details.version) · \(details.head)")
        }
        if summary.checkedAt > 0 {
            let when = Date(timeIntervalSince1970: summary.checkedAt / 1000)
            parts.append(String(format: String(localized: "перевірено %@"),
                                when.formatted(.relative(presentation: .named))))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func lastInstall(_ details: UpdateDetails) -> some View {
        let when = details.installFinishedAt > 0
            ? Date(timeIntervalSince1970: details.installFinishedAt / 1000).formatted(.relative(presentation: .named))
            : ""

        if summary.install == "done" {
            Label {
                Text(String(format: String(localized: "Оновлено до %1$@ %2$@"), details.installTo, when))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Оновити не вдалося")
                        Text(stepText(details.installStep))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }

                Spacer()

                if !details.log.isEmpty {
                    Button("Показати лог") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: details.log))
                    }
                }
            }
        }
    }

    private func stepText(_ step: String) -> String {
        switch step {
        case "pull":    return String(localized: "git pull не пройшов — тут є свої зміни, що розходяться з GitHub")
        case "install": return String(localized: "впала установка або збірка програми")
        case "stale":   return String(localized: "скрипт оновлення так і не відповів")
        default:        return step
        }
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

    private func install() {
        Task {
            if let fresh = await client.installUpdate() { details = fresh }
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
