import SwiftUI

// Розділ «Сесії»: відкриті проєкти картками, у кожній — її сесії.
//
// Закриті проєкти лишаються в реєстрі демона з кольорами й іконками, але
// тут не показуються.

/// Яке вікно зараз відкрите поверх списку. Один enum замість кількох
/// @State — інакше кілька .sheet на одній вʼюшці конфліктують між собою.
enum SessionSheet: Identifiable {
    case details(Session)
    case edit(Session)
    case project(Project)

    var id: String {
        switch self {
        case .details(let s): return "details-\(s.sid)"
        case .edit(let s):    return "edit-\(s.sid)"
        case .project(let p): return "project-\(p.path)"
        }
    }
}

/// Дія, яка потребує підтвердження.
enum SessionConfirm: Identifiable {
    case forget(Session)
    case compact(Session)

    var id: String {
        switch self {
        case .forget(let s):  return "forget-\(s.sid)"
        case .compact(let s): return "compact-\(s.sid)"
        }
    }

    var session: Session {
        switch self {
        case .forget(let s), .compact(let s): return s
        }
    }
}

struct SessionsPane: View {
    @ObservedObject var client: DaemonClient

    @State private var sheet: SessionSheet?
    @State private var confirm: SessionConfirm?

    private var projects: [Project] { client.state?.sortedProjects ?? [] }

    var body: some View {
        Group {
            if projects.isEmpty {
                EmptyStateView(client: client)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let state = client.state {
                            SummaryStrip(state: state)
                        }

                        ForEach(projects) { project in
                            ProjectCard(
                                project: project,
                                client: client,
                                sheet: $sheet,
                                confirm: $confirm
                            )
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(SidebarItem.sessions.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Демон і сам перевіряє живучість сесій, але коли ти щойно
                // закрив вкладку й дивишся у вікно, чекати не хочеться.
                Button {
                    Task { await client.forceRefresh() }
                } label: {
                    Label("Оновити список", systemImage: "arrow.clockwise")
                }
                .disabled(client.isRefreshing)
                .help("Оновити зараз: перевірити, чи живі сесії")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .details(let session):
                // Свіжа копія зі стану, щоб цифри оновлювались, поки
                // вікно відкрите.
                SessionDetails(session: live(session) ?? session)

            case .edit(let session):
                SessionEditor(session: live(session) ?? session) { alias, notify in
                    await client.saveSession(sid: session.sid, alias: alias, notify: notify)
                }

            case .project(let project):
                ProjectEditor(project: liveProject(project) ?? project) { color, icon in
                    await client.saveProject(path: project.path, color: color, icon: icon)
                }
            }
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            titleVisibility: .visible,
            presenting: confirm
        ) { which in
            switch which {
            case .forget(let session):
                Button("Прибрати", role: .destructive) {
                    Task { await client.forgetSession(sid: session.sid) }
                }
            case .compact(let session):
                Button("Стиснути") {
                    Task { await client.compact(sid: session.sid) }
                }
            }
            Button("Скасувати", role: .cancel) { }
        } message: { which in
            switch which {
            case .forget:
                Text(String(localized: "Сама сесія не зупиниться — вона лише зникне зі списку. ")
                     + String(localized: "Якщо вона ще жива, повернеться з наступною своєю подією."))
            case .compact:
                Text(String(localized: "Claude підсумує розмову й почне з коротшого контексту. ")
                     + String(localized: "Подробиці з початку розмови можуть загубитись."))
            }
        }
    }

    private var subtitle: String {
        guard let state = client.state, client.isConnected else {
            return String(localized: "немає зв'язку з демоном")
        }
        return String(format: String(localized: "%1$d відкрито · %2$d сесій"),
                      state.sortedProjects.count, state.sessions.count)
    }

    private var confirmTitle: String {
        switch confirm {
        case .forget(let s)?:  return String(format: String(localized: "Прибрати «%@» зі списку?"), s.title)
        case .compact(let s)?: return String(format: String(localized: "Стиснути контекст «%@»?"), s.title)
        case nil:              return ""
        }
    }

    private func live(_ session: Session) -> Session? {
        client.state?.sessions.first { $0.sid == session.sid }
    }

    private func liveProject(_ project: Project) -> Project? {
        client.state?.projects.first { $0.path == project.path }
    }
}

// MARK: - Зведення

/// Скільки сесій у якому стані — кольоровими плашками над картками.
private struct SummaryStrip: View {
    let state: DaemonState

    var body: some View {
        HStack(spacing: 8) {
            chip(state.needsAttentionCount, .needsInput)
            chip(state.workingCount, .working)
            chip(state.waitingCount, .waiting)
            Spacer()
        }
    }

    @ViewBuilder
    private func chip(_ count: Int, _ status: SessionStatus) -> some View {
        if count > 0 {
            StatusPill(text: "\(count) · \(status.title)", color: status.color)
        }
    }
}

// MARK: - Картка проєкту

private struct ProjectCard: View {
    let project: Project
    @ObservedObject var client: DaemonClient
    @Binding var sheet: SessionSheet?
    @Binding var confirm: SessionConfirm?

    private var sessions: [Session] {
        project.sessions.sorted { $0.since < $1.since }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            if sessions.isEmpty {
                Divider().padding(.leading, 14)
                Text("Немає активних сесій")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ForEach(sessions) { session in
                    Divider().padding(.leading, 14)
                    SessionRow(
                        session: session,
                        client: client,
                        sheet: $sheet,
                        confirm: $confirm
                    )
                }
            }
        }
        .card()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(icon: project.iconName, color: project.accent, size: 38)
                .opacity(project.isLive ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: project.displayName)
                    .font(.headline)

                HStack(spacing: 10) {
                    if let terminals = project.terminalsText {
                        Label(terminals, systemImage: "terminal")
                    } else {
                        Text(verbatim: abbreviated(project.path))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    // Сесію відкрито до встановлення хуків — вона працює,
                    // але демон про неї нічого не знає.
                    if project.untracked > 0 {
                        Label(String(format: String(localized: "%d без сповіщень"), project.untracked),
                              systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                            .help("Сесію відкрито до встановлення хуків — перезапусти її, щоб отримувати сповіщення")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if project.isLive {
                StatusPill(text: project.state.title, color: project.state.color)
            }

            // Тиша для всієї групи: банери лишаються, звук — ні.
            Button {
                Task { await client.setProjectSilent(path: project.path, silent: !project.settings.silent) }
            } label: {
                Image(systemName: project.settings.silent ? "speaker.slash.fill" : "speaker.wave.2")
                    .foregroundStyle(project.settings.silent ? Color.orange : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(project.settings.silent
                  ? String(localized: "Увімкнути звук сповіщень цього проєкту")
                  : String(localized: "Вимкнути звук сповіщень цього проєкту"))

            Button {
                sheet = .project(project)
            } label: {
                Image(systemName: "paintbrush")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Колір та іконка проєкту")
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Рядок сесії

private struct SessionRow: View {
    let session: Session
    @ObservedObject var client: DaemonClient
    @Binding var sheet: SessionSheet?
    @Binding var confirm: SessionConfirm?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(status: session.state)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: session.title)
                        .font(.body.weight(.semibold))

                    // Хто це: Claude Code чи Codex — видно одразу.
                    Tag(text: session.isCodex ? "Codex" : "Claude",
                        color: session.isCodex ? .teal : .orange)

                    // Видно з першого погляду, що ця сесія мовчить.
                    if !session.notifyEnabled {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Сповіщення цієї сесії вимкнено")
                    }
                }

                HStack(spacing: 5) {
                    Text(session.state.title)
                        .foregroundStyle(session.state == .needsInput ? session.state.color : .secondary)

                    if let duration = session.durationText {
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(verbatim: duration)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }

            Spacer(minLength: 8)

            if !session.isCodex {
                ModeMenu(session: session) { mode in
                    Task { await client.setMode(sid: session.sid, mode: mode) }
                }
            }

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Дії з сесією")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { sheet = .details(session) }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            sheet = .details(session)
        } label: {
            Label("Деталі", systemImage: "info.circle")
        }

        Button {
            sheet = .edit(session)
        } label: {
            Label("Назва й сповіщення…", systemImage: "pencil")
        }

        // Слеш-команди й клавіші доходять лише туди, де є посередник:
        // tmux (`start`) або власний термінал демона.
        if session.canInput {
            Divider()

            if !session.isCodex {
                Menu {
                    Section("Стає типовою і для нових сесій") {
                        ForEach(ClaudeModel.allCases) { model in
                            Button("\(model.title) — \(model.hint)") {
                                Task { await client.setModel(sid: session.sid, model: model.rawValue) }
                            }
                        }
                    }
                } label: {
                    Label("Модель", systemImage: "cpu")
                }

                Menu {
                    Section("Стає типовим і для нових сесій") {
                        ForEach(EffortLevel.allCases) { level in
                            Button {
                                Task { await client.setEffort(sid: session.sid, effort: level.rawValue) }
                            } label: {
                                if level.rawValue == session.effort {
                                    Label("\(level.title) — \(level.hint)", systemImage: "checkmark")
                                } else {
                                    Text("\(level.title) — \(level.hint)")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Зусилля", systemImage: "gauge.with.dots.needle.67percent")
                }
            }

            Button {
                confirm = .compact(session)
            } label: {
                Label("Стиснути контекст…", systemImage: "arrow.down.right.and.arrow.up.left")
            }

            if session.state == .working {
                Button {
                    Task { await client.interrupt(sid: session.sid) }
                } label: {
                    Label("Перервати хід", systemImage: "stop.circle")
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            confirm = .forget(session)
        } label: {
            Label("Прибрати зі списку", systemImage: "xmark.circle")
        }
    }
}

/// Поточний режим дозволів. Клік дає перемкнути — демон тисне
/// Shift+Tab стільки разів, скільки треба.
private struct ModeMenu: View {
    let session: Session
    var onPick: (String) -> Void

    private var current: PermissionMode? { PermissionMode(rawValue: session.permissionMode) }

    var body: some View {
        if session.canInput {
            Menu {
                ForEach(PermissionMode.allCases) { mode in
                    Button {
                        onPick(mode.rawValue)
                    } label: {
                        Label("\(mode.title) — \(mode.hint)", systemImage: mode.symbol)
                    }
                    .disabled(mode == current)
                }
            } label: {
                chip
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Режим дозволів")
        } else if current != nil {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Image(systemName: current?.symbol ?? "questionmark")
            Text(current?.title ?? String(localized: "режим?"))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(current == .plan ? Color.purple : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (current == .plan ? Color.purple : Color.primary).opacity(0.08),
            in: Capsule()
        )
    }
}
