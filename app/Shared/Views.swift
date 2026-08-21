import SwiftUI

// Екрани, спільні для macOS та iOS. Платформні файли лише загортають їх
// у своє вікно / навігацію.

extension SessionStatus {
    var color: Color {
        switch self {
        case .idle:       return .secondary
        case .working:    return .blue
        case .waiting:    return .green
        case .needsInput: return .orange
        }
    }
}

extension ProjectStatus {
    var color: Color {
        switch self {
        case .needsInput: return .orange
        case .waiting:    return .green
        case .working:    return .blue
        case .idle:       return .secondary
        case .offline:    return .secondary
        }
    }
}

// MARK: - Проєкти

/// Яке вікно зараз відкрите поверх списку.
/// Один enum замість двох окремих @State — інакше два .sheet на одній
/// в'юшці конфліктують між собою.
enum SessionSheet: Identifiable {
    case details(Session)
    case edit(Session)
    case project(Project)
    case chat(Session)

    var id: String {
        switch self {
        case .details(let s): return "details-\(s.sid)"
        case .edit(let s):    return "edit-\(s.sid)"
        case .project(let p): return "project-\(p.path)"
        case .chat(let s):    return "chat-\(s.sid)"
        }
    }
}

/// Головний екран: проєкти, відкриті прямо зараз, під кожним — його сесії.
/// Закриті проєкти лишаються в реєстрі демона, але тут не показуються.
struct ProjectsView: View {
    @ObservedObject var client: DaemonClient
    @State private var sheet: SessionSheet?

    /// Сесія, яку збираються прибрати. Поки не порожня — питаємо.
    @State private var forgetTarget: Session?

    var body: some View {
        Group {
            if let state = client.state, !state.sortedProjects.isEmpty {
                List {
                    ForEach(state.sortedProjects) { project in
                        Section {
                            if project.sessions.isEmpty {
                                Text("немає активних сесій")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(project.sessions.sorted { $0.since < $1.since }) { session in
                                    SessionRow(
                                        session: session,
                                        onChat: { sheet = .chat(session) },
                                        onDetails: { sheet = .details(session) },
                                        onEdit: { sheet = .edit(session) },
                                        onMode: { mode in
                                            Task { await client.setMode(sid: session.sid, mode: mode) }
                                        },
                                        onForget: { forgetTarget = session }
                                    )
                                }
                            }
                        } header: {
                            ProjectHeader(
                                project: project,
                                onEdit: { sheet = .project(project) },
                                onStartSession: {
                                    Task {
                                        await client.spawnSession(
                                            projectPath: project.path,
                                            label: project.name
                                        )
                                    }
                                }
                            )
                        }
                    }
                }
            } else {
                EmptyStateView(client: client)
            }
        }
        .confirmationDialog(
            forgetTarget.map { String(format: String(localized: "Прибрати «%@» зі списку?"), $0.title) } ?? "",
            isPresented: Binding(
                get: { forgetTarget != nil },
                set: { if !$0 { forgetTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: forgetTarget
        ) { session in
            Button("Прибрати", role: .destructive) {
                Task { await client.forgetSession(sid: session.sid) }
                forgetTarget = nil
            }
            Button("Скасувати", role: .cancel) { forgetTarget = nil }
        } message: { _ in
            Text(String(localized: "Сама сесія не зупиниться — вона лише зникне зі списку. ")
                 + String(localized: "Якщо вона ще жива, повернеться з наступною своєю подією."))
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .details(let session):
                // Беремо свіжу копію зі стану, щоб цифри в деталях
                // оновлювались, поки вікно відкрите.
                SessionDetails(session: live(session) ?? session)

            case .edit(let session):
                SessionEditor(session: live(session) ?? session) { alias, notify in
                    await client.saveSession(sid: session.sid, alias: alias, notify: notify)
                }

            case .chat(let session):
                ChatView(session: live(session) ?? session, client: client)

            case .project(let project):
                ProjectEditor(project: liveProject(project) ?? project) { color, icon in
                    await client.saveProject(path: project.path, color: color, icon: icon)
                }
            }
        }
    }

    /// Актуальна версія сесії з останнього знімка стану.
    private func live(_ session: Session) -> Session? {
        client.state?.sessions.first { $0.sid == session.sid }
    }

    private func liveProject(_ project: Project) -> Project? {
        client.state?.projects.first { $0.path == project.path }
    }
}

struct ProjectHeader: View {
    let project: Project
    var onEdit: () -> Void
    var onStartSession: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                LucideIcon(name: project.iconName, size: 17)
                    .foregroundStyle(project.accent)
                    .opacity(project.isLive ? 1 : 0.5)

                Text(project.displayName)
                    .font(.headline)
                    .foregroundStyle(project.isLive ? .primary : .secondary)

                Spacer()

                Text(project.sessionCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let onStartSession {
                    Button(action: onStartSession) {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Запустити сесію Claude тут — у неї можна буде писати з програми")
                }

                Button(action: onEdit) {
                    Image(systemName: "paintbrush")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Колір та іконка проєкту")
            }

            // Те, що видно в самій системі, а не через хуки: скільки
            // вкладок термінала відкрито і де з них працює Claude.
            HStack(spacing: 6) {
                if let terminals = project.terminalsText {
                    Label(terminals, systemImage: "terminal")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if project.untracked > 0 {
                    Label(String(format: String(localized: "%d без сповіщень"), project.untracked), systemImage: "bell.slash")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                        .help("Сесію відкрито до встановлення хуків — перезапусти її, щоб отримувати сповіщення")
                }
            }
            .padding(.leading, 16)
        }
        .padding(.vertical, 3)
        .textCase(nil)
    }
}

/// Колір та іконка проєкту. Зберігаються демоном, тому діють і на телефоні.
struct ProjectEditor: View {
    let project: Project
    var onSave: (String, String) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var color: String = ""
    @State private var icon: String = ""
    @State private var isSaving = false

    private var preview: Color { Palette.color(color) ?? .secondary }

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LucideIcon(name: icon.isEmpty ? Lucide.fallback : icon, size: 26)
                    .foregroundStyle(preview)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.headline)
                    Text(project.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.bottom, 18)

            Text("Колір")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 7)

            HStack(spacing: 8) {
                ForEach(Palette.names, id: \.self) { name in
                    Button {
                        color = (color == name) ? "" : name
                    } label: {
                        Circle()
                            .fill(Palette.color(name) ?? .gray)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle()
                                    .strokeBorder(.primary, lineWidth: color == name ? 2 : 0)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(Palette.titles[name] ?? name)
                }
            }
            .padding(.bottom, 20)

            Text("Іконка")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 7)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Lucide.names, id: \.self) { name in
                    Button {
                        icon = (icon == name) ? "" : name
                    } label: {
                        LucideIcon(name: name, size: 20)
                            .foregroundStyle(icon == name ? preview : .secondary)
                            .frame(width: 40, height: 34)
                            .background {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(icon == name ? preview.opacity(0.15) : .clear)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 22)

            HStack {
                Button("Скинути") {
                    color = ""
                    icon = ""
                }
                .disabled(color.isEmpty && icon.isEmpty)

                Spacer()

                Button("Скасувати") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Зберегти") {
                    isSaving = true
                    Task {
                        await onSave(color, icon)
                        isSaving = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(22)
        .windowSize(minWidth: 380)
        .onAppear {
            color = project.settings.color
            icon = project.settings.icon
        }
    }
}

// MARK: - Сесії

struct SessionRow: View {
    let session: Session
    var onChat: () -> Void
    var onDetails: () -> Void
    var onEdit: () -> Void
    var onMode: ((String) -> Void)? = nil
    var onForget: (() -> Void)? = nil

    /// Другий рядок під статусом: час турна і скільки токенів зʼїдено.
    private var meta: String? {
        var parts: [String] = []
        if let duration = session.durationText { parts.append(duration) }
        if !session.tokens.isEmpty { parts.append(String(format: String(localized: "%@ токенів"), Format.tokens(session.tokens.total))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.state.symbol)
                .foregroundStyle(session.state.color)
                .font(.title3)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.title)
                        .font(.body.weight(.medium))

                    // Видно з першого погляду, що ця сесія мовчить.
                    if !session.notifyEnabled {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(session.state.title)
                    .font(.caption)
                    .foregroundStyle(session.state == .needsInput ? session.state.color : .secondary)

                if let meta {
                    Text(meta)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            modePicker

            HStack(spacing: 10) {
                Button(action: onChat) {
                    Image(systemName: "text.bubble")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Переписка сесії")

                Button(action: onDetails) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Детальна інформація")

                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Налаштування сесії")

                if let onForget {
                    Button(action: onForget) {
                        Image(systemName: "xmark.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Прибрати зі списку — якщо цю сесію вже закрито")
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Поточний режим дозволів. Клік дає перемкнути — демон тисне
    /// Shift+Tab стільки разів, скільки треба.
    @ViewBuilder
    private var modePicker: some View {
        let current = PermissionMode(rawValue: session.permissionMode)

        if let onMode, session.canInput {
            Menu {
                ForEach(PermissionMode.allCases) { mode in
                    Button {
                        onMode(mode.rawValue)
                    } label: {
                        Label("\(mode.title) — \(mode.hint)", systemImage: mode.symbol)
                    }
                    .disabled(mode == current)
                }
            } label: {
                modeChip(current)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Режим дозволів")
        } else if let current {
            modeChip(current)
        }
    }

    private func modeChip(_ mode: PermissionMode?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: mode?.symbol ?? "questionmark")
                .font(.caption2)
            Text(mode?.title ?? String(localized: "режим?"))
                .font(.caption2)
        }
        .foregroundStyle(mode == .plan ? Color.purple : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

// MARK: - Деталі сесії

/// Детальна інформація: скільки сесія працювала сумарно і скільки зʼїла.
struct SessionDetails: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.vertical, 16)

            block(String(localized: "Час")) {
                row(String(localized: "Загальний час роботи"), Format.duration(Double(session.totalWorkSeconds)),
                    accent: true)
                row(String(localized: "Турнів"), "\(session.turns)")
                if let last = session.lastTurnSeconds {
                    row(String(localized: "Останній турн"), Format.duration(last))
                }
                row(String(localized: "Сесія відкрита"), Format.duration(Double(session.ageSeconds)))
            }

            Divider().padding(.vertical, 16)

            if session.tokens.isEmpty {
                Text("Токени зʼявляться після першої відповіді")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                block(String(localized: "Токени")) {
                    row(String(localized: "Разом"), Format.tokensFull(session.tokens.total), accent: true)
                    row(String(localized: "Свіжий контекст"), Format.tokensFull(session.tokens.input))
                    row(String(localized: "Запис у кеш"), Format.tokensFull(session.tokens.cacheWrite))
                    row(String(localized: "Читання з кешу"), Format.tokensFull(session.tokens.cacheRead))
                    row(String(localized: "Відповіді"), Format.tokensFull(session.tokens.output))
                    if session.tokens.thinking > 0 {
                        row(String(localized: "з них міркування"), Format.tokensFull(session.tokens.thinking),
                            muted: true)
                    }
                    row(String(localized: "Відповідей"), "\(session.tokens.messages)")
                    if !session.tokens.model.isEmpty {
                        row(String(localized: "Модель"), session.tokens.model)
                    }
                }
            }

            Spacer(minLength: 20)

            HStack {
                Spacer()
                Button("Закрити") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .windowSize(minWidth: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: session.state.symbol)
                .foregroundStyle(session.state.color)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.headline)
                Text(session.project.isEmpty ? session.state.title
                                             : "\(session.project) · \(session.state.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func block<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            content()
        }
    }

    private func row(_ label: String, _ value: String,
                     accent: Bool = false, muted: Bool = false) -> some View {
        HStack {
            Text(muted ? "    \(label)" : label)
                .font(muted ? .caption2 : .callout)
                .foregroundStyle(muted ? .tertiary : .secondary)

            Spacer(minLength: 16)

            Text(value)
                .font(accent ? .callout.bold().monospacedDigit()
                             : (muted ? .caption2.monospacedDigit() : .callout.monospacedDigit()))
                .foregroundStyle(muted ? .tertiary : .primary)
        }
    }
}

/// Редагування однієї сесії: своя назва та вимикач сповіщень.
struct SessionEditor: View {
    let session: Session
    var onSave: (String, Bool) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var notify: Bool = true
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Налаштування сесії")
                .font(.headline)
                .padding(.bottom, 4)

            Text(session.project.isEmpty ? session.sid : session.project)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 6) {
                Text("Назва")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField(session.label, text: $name)
                    .textFieldStyle(.roundedBorder)

                Text("Порожнє поле поверне початкову мітку «\(session.label)»")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 18)

            Toggle(isOn: $notify) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Сповіщення про цю сесію")
                    Text("Банери, коли вона закінчить роботу або чекатиме на дозвіл")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 22)

            HStack {
                Spacer()

                Button("Скасувати") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Зберегти") {
                    isSaving = true
                    Task {
                        await onSave(name.trimmingCharacters(in: .whitespaces), notify)
                        isSaving = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(22)
        .windowSize(minWidth: 360)
        .onAppear {
            name = session.alias
            notify = session.notifyEnabled
        }
    }
}

// MARK: - Допоміжні

struct EmptyStateView: View {
    @ObservedObject var client: DaemonClient

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: client.isConnected ? "moon.zzz" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text(client.isConnected ? String(localized: "Проєктів поки немає") : String(localized: "Немає зв'язку з демоном"))
                .font(.headline)

            Text(client.isConnected
                 ? String(localized: "Запусти Claude Code — проєкт зʼявиться тут і залишиться назавжди")
                 : (client.lastError ?? String(localized: "Перевір, чи демон запущено")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Смужка стану з'єднання — однакова на обох платформах.
struct ConnectionBar: View {
    @ObservedObject var client: DaemonClient
    @State private var showPairing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text(client.isConnected
                 ? (client.state?.host ?? String(localized: "підключено"))
                 : (client.needsPairing ? String(localized: "потрібен ключ") : String(localized: "немає зв'язку")))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let state = client.state, client.isConnected {
                Text(String(format: String(localized: "%d відкрито · %d сесій"), state.sortedProjects.count, state.sessions.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            // Підключення телефона кодом — на випадок, коли Bonjour
            // у мережі не працює.
            Button {
                showPairing = true
            } label: {
                Image(systemName: "qrcode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Підключити телефон")
            .sheet(isPresented: $showPairing) {
                PairingView(client: client)
            }
            #endif

            // Демон і сам перевіряє живучість сесій, але коли ти щойно
            // закрив вкладку й дивишся у вікно, чекати не хочеться.
            Button {
                Task { await client.forceRefresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(client.isRefreshing ? 360 : 0))
                    .animation(client.isRefreshing
                               ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                               : .default,
                               value: client.isRefreshing)
            }
            .buttonStyle(.borderless)
            .disabled(client.isRefreshing)
            .help("Оновити зараз: перевірити, чи живі сесії")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
