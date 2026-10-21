import SwiftUI

// Вікна поверх списку сесій: деталі, назва й сповіщення сесії, колір та
// іконка проєкту — і порожній стан, коли показувати нічого.

// MARK: - Деталі сесії

/// Скільки сесія працювала і як вона налаштована.
struct SessionDetails: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            LazyVGrid(columns: columns, spacing: 10) {
                StatTile(title: String(localized: "Загальний час роботи"),
                         value: Format.duration(Double(session.totalWorkSeconds)),
                         accent: .accentColor)
                StatTile(title: String(localized: "Турнів"), value: "\(session.turns)")
                StatTile(title: String(localized: "Останній турн"),
                         value: session.lastTurnSeconds.map(Format.duration) ?? "—")
                StatTile(title: String(localized: "Сесія відкрита"),
                         value: Format.duration(Double(session.ageSeconds)))
                // Разом із тим, що агент запустив: MCP-сервери, браузер.
                StatTile(title: String(localized: "Памʼять"), value: session.memoryText ?? "—")
                StatTile(title: String(localized: "Процесів"),
                         value: session.memory.map { "\($0.processes)" } ?? "—")
            }

            VStack(spacing: 8) {
                info(String(localized: "Агент"), session.isCodex ? "Codex" : "Claude Code")

                if !session.isCodex {
                    if let mode = PermissionMode(rawValue: session.permissionMode) {
                        info(String(localized: "Режим дозволів"), mode.title)
                    }
                    if let effort = EffortLevel(rawValue: session.effort) {
                        info(String(localized: "Зусилля"), effort.title)
                    }
                }

                if !session.cwd.isEmpty {
                    info(String(localized: "Тека"), (session.cwd as NSString).abbreviatingWithTildeInPath)
                }

                info(String(localized: "Ввід ззовні"),
                     session.canInput ? String(localized: "так, через tmux") : String(localized: "ні — сесію запущено без start"))
            }

            HStack {
                Spacer()
                Button("Закрити") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatusBadge(status: session.state, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: session.title)
                    .font(.title3.weight(.semibold))
                Text(session.project.isEmpty ? session.state.title
                                             : "\(session.project) · \(session.state.title)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

// MARK: - Назва й сповіщення сесії

struct SessionEditor: View {
    let session: Session
    var onSave: (String, Bool) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var notify: Bool = true
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                StatusBadge(status: session.state, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Налаштування сесії")
                        .font(.headline)
                    Text(verbatim: session.project.isEmpty ? session.sid : session.project)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Назва")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField(session.label, text: $name)
                    .textFieldStyle(.roundedBorder)

                Text(String(format: String(localized: "Порожнє поле поверне початкову мітку «%@»"), session.label))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Toggle(isOn: $notify) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Сповіщення про цю сесію")
                    Text("Банери, коли вона закінчить роботу або чекатиме на дозвіл")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

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
        .frame(width: 400)
        .onAppear {
            name = session.alias
            notify = session.notifyEnabled
        }
    }
}

// MARK: - Колір та іконка проєкту

/// Зберігаються демоном, тож діють і в банерах.
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
            HStack(spacing: 12) {
                IconTile(icon: icon.isEmpty ? Lucide.fallback : icon, color: preview, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: project.name).font(.headline)
                    Text(verbatim: (project.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.bottom, 20)

            Text("Колір")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            HStack(spacing: 10) {
                ForEach(Palette.names, id: \.self) { name in
                    Button {
                        color = (color == name) ? "" : name
                    } label: {
                        Circle()
                            .fill(Palette.color(name) ?? .gray)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if color == name {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
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
                .padding(.bottom, 8)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Lucide.names, id: \.self) { name in
                    Button {
                        icon = (icon == name) ? "" : name
                    } label: {
                        LucideIcon(name: name, size: 20)
                            .foregroundStyle(icon == name ? preview : .secondary)
                            .frame(width: 42, height: 36)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(icon == name ? preview.opacity(0.16) : Color.primary.opacity(0.04))
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
        .frame(width: 420)
        .onAppear {
            color = project.settings.color
            icon = project.settings.icon
        }
    }
}

// MARK: - Порожньо

struct EmptyStateView: View {
    @ObservedObject var client: DaemonClient

    var body: some View {
        VStack(spacing: 14) {
            Circle()
                .fill((client.isConnected ? Color.blue : Color.orange).opacity(0.12))
                .frame(width: 84, height: 84)
                .overlay {
                    Image(systemName: client.isConnected ? "moon.zzz.fill" : "bolt.horizontal.circle")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(client.isConnected ? Color.blue : Color.orange)
                }

            Text(client.isConnected ? String(localized: "Проєктів поки немає") : String(localized: "Немає зв'язку з демоном"))
                .font(.title3.weight(.semibold))

            Text(client.isConnected
                 ? String(localized: "Запусти Claude Code командою start — проєкт зʼявиться тут")
                 : String(localized: "Перевір, чи демон запущено: npm run restart, а що з ним — npm run logs"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
