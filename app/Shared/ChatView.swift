import SwiftUI

// Перегляд переписки сесії.
//
// Для живої сесії екран оновлюється сам: демон дочитує транскрипт кожні
// дві секунди, а тут ми так само часто перезапитуємо хвіст розмови.
// Прокрутка при цьому тримається внизу — доки ти сам не прогорнув угору
// або не почав шукати.

struct ChatView: View {
    let session: Session
    @ObservedObject var client: DaemonClient

    @Environment(\.dismiss) private var dismiss

    // Скільки останніх повідомлень тягнемо в живому режимі. Для довгих
    // сесій качати все щодві секунди було б марно.
    private static let tailLimit = 300

    @State private var messages: [ArchivedMessage] = []
    @State private var meta: ArchivedSession?
    @State private var isLoading = true
    @State private var showAll = false
    @State private var query = ""
    @State private var follow = true
    @State private var draft = ""
    @State private var isSending = false
    @State private var confirmCompact = false
    @State private var busyWith = ""      // яку команду шлемо просто зараз

    private var isLive: Bool {
        session.state == .working || session.state == .needsInput
    }

    private var visible: [ArchivedMessage] {
        guard !query.isEmpty else { return messages }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var hasMore: Bool {
        guard let meta else { return false }
        return !showAll && meta.messages > messages.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            composer
        }
        .windowSize(minWidth: 540, minHeight: 440)
        .confirmationDialog(
            "Стиснути контекст сесії?",
            isPresented: $confirmCompact,
            titleVisibility: .visible
        ) {
            Button("Стиснути") { run("compact") { await client.compact(sid: session.sid) } }
            Button("Скасувати", role: .cancel) { }
        } message: {
            Text("Claude підсумує розмову й почне з коротшого контексту. "
                 + "Переписка в архіві лишиться цілою.")
        }
        .task(id: showAll) {
            await reload()
            isLoading = false

            // Живу сесію тримаємо свіжою; закінчену досить прочитати раз.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                await reload()
            }
        }
    }

    // ------------------------------------------------------------ шапка

    @ViewBuilder
    private var header: some View {
        if Platform.isPhone {
            // На телефоні все в один стовпчик: рядок пошуку на всю
            // ширину, без кнопки закриття — вікно змахується вниз.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    titleBlock
                    Spacer(minLength: 8)
                    controls
                }

                HStack(spacing: 8) {
                    TextField("Пошук", text: $query)
                        .textFieldStyle(.roundedBorder)

                    if hasMore {
                        Button("Уся історія") { showAll = true }
                            .font(.caption)
                    }
                }
            }
            .padding(14)
        } else {
            HStack(spacing: 10) {
                titleBlock

                Spacer()

                if hasMore {
                    Button("Уся історія") { showAll = true }
                        .buttonStyle(.borderless)
                }

                controls

                TextField("Пошук", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)

                Button("Закрити") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.title).font(.headline)

                if isLive {
                    Circle()
                        .fill(session.state.color)
                        .frame(width: 7, height: 7)
                    Text("наживо")
                        .font(.caption2)
                        .foregroundStyle(session.state.color)
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts: [String] = []

        let project = meta?.project.isEmpty == false ? meta!.project : session.project
        if !project.isEmpty { parts.append(project) }

        if let meta {
            let shown = query.isEmpty ? messages.count : visible.count
            let of = meta.messages > messages.count ? " з \(meta.messages)" : ""
            parts.append("\(shown)\(of) повідомлень")
        }

        if let model = currentModel { parts.append(model.title) }
        if let effort = currentEffort { parts.append("зусилля \(effort.title)") }

        return parts.joined(separator: " · ")
    }

    /// Модель беремо з токенів: там повна назва з транскрипту, тобто те,
    /// чим Claude справді відповідала востаннє.
    private var currentModel: ClaudeModel? {
        ClaudeModel.allCases.first { $0.matches(session.tokens.model) }
    }

    private var currentEffort: EffortLevel? {
        EffortLevel(rawValue: session.effort)
    }

    // ------------------------------------------------------ керування

    /// Модель, зусилля і стиснення контексту — усе під однією кнопкою.
    /// На телефоні місця мало, а тиснути це доводиться зрідка.
    @ViewBuilder
    private var controls: some View {
        if session.canInput {
            Menu {
                Section("Модель") {
                    ForEach(ClaudeModel.allCases) { model in
                        Button {
                            run("model") { await client.setModel(sid: session.sid, model: model.rawValue) }
                        } label: {
                            Label("\(model.title) — \(model.hint)",
                                  systemImage: currentModel == model ? "checkmark" : "cpu")
                        }
                        .disabled(currentModel == model)
                    }
                }

                Section("Зусилля (типово для нових сесій)") {
                    ForEach(EffortLevel.allCases) { level in
                        Button {
                            run("effort") { await client.setEffort(sid: session.sid, effort: level.rawValue) }
                        } label: {
                            Label("\(level.title) — \(level.hint)",
                                  systemImage: currentEffort == level ? "checkmark" : "gauge.medium")
                        }
                        .disabled(currentEffort == level)
                    }
                }

                Section {
                    Button {
                        confirmCompact = true
                    } label: {
                        Label("Стиснути контекст", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
            } label: {
                if busyWith.isEmpty {
                    Image(systemName: "slider.horizontal.3")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!busyWith.isEmpty)
            .help("Модель, зусилля, стиснення контексту")
        }
    }

    /// Спільна обгортка для команд: показати зайнятість і не дати
    /// натиснути двічі, доки перша не дійшла.
    private func run(_ what: String, _ action: @escaping () async -> Bool) {
        guard busyWith.isEmpty else { return }
        busyWith = what

        Task {
            _ = await action()
            // Команда лишає слід у самій сесії, тож підтягнемо переписку.
            await reload()
            busyWith = ""
        }
    }

    // ------------------------------------------------------------ вміст

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if messages.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(visible) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        // Якір, до якого прокручуємось: сам останній рядок
                        // у LazyVStack може бути ще не створений.
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    guard follow, query.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private let bottomAnchor = "chat-bottom"

    // ------------------------------------------------------------ ввід

    @ViewBuilder
    private var composer: some View {
        if session.canInput {
            HStack(spacing: 8) {
                TextField("Запит до сесії…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(isSending)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(12)
        } else {
            // Сесію запустили без посередника, тому писати в неї нікуди.
            HStack(spacing: 7) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .foregroundStyle(.tertiary)

                Text("Цю сесію запущено без tmux — писати в неї ззовні macOS не дозволяє. "
                     + "Перезапусти її командою start, і ввід зʼявиться.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        isSending = true
        draft = ""
        follow = true

        Task {
            await client.sendInput(sid: session.sid, text: text)
            isSending = false
            // Відповідь зʼявиться в архіві сама — його дочитує демон.
            await reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Переписки ще немає")
                .font(.headline)

            Text("Вона зʼявиться після першої відповіді в цій сесії")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ------------------------------------------------------------ дані

    private func reload() async {
        let limit = showAll ? 0 : Self.tailLimit
        guard let response = await client.loadHistory(sid: session.sid, limit: limit) else { return }

        // Не чіпаємо масив, якщо нічого не змінилось — інакше SwiftUI
        // перемальовував би список щодві секунди без потреби.
        if response.messages != messages {
            messages = response.messages
        }
        meta = response.session
    }
}

/// Одне повідомлення у стрічці.
///
/// Головне тут — не потонути в інструментах. Клич до Bash чи Read
/// трапляється по кілька разів на відповідь, і якщо кожен малювати
/// капсулою з підписом «Claude», стрічка перетворюється на список
/// слова «Bash». Тому:
///
///   • повідомлення без тексту, лише з інструментами, — це тонкий сірий
///     рядок без шапки й бульбашки;
///   • однакові інструменти згортаються в «Bash ×3»;
///   • час відповіді показуємо там, де турн завершився.
struct MessageBubble: View {
    let message: ArchivedMessage

    private var accent: Color { message.isUser ? .blue : .secondary }

    var body: some View {
        if message.isToolsOnly {
            toolLine
        } else {
            VStack(alignment: .leading, spacing: 5) {
                header

                if !message.text.isEmpty {
                    // Відповіді Claude — це маркдаун: заголовки, списки,
                    // таблиці, код. Показувати його сирим означало б
                    // читати "## Вигляд" і "| а | б |" очима.
                    MarkdownText(source: message.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(message.isUser ? Color.blue.opacity(0.10)
                                                     : Color.gray.opacity(0.10))
                        }
                }

                if !message.tools.isEmpty { toolLine }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(message.isUser ? "Ти" : "Claude")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)

            Text(Format.clock.string(from: message.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            // Скільки Claude думала над цією відповіддю. Рахує демон, і
            // ставить лише там, де турн завершився.
            if let seconds = message.replySeconds {
                Label(Format.duration(seconds), systemImage: "clock")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// Інструменти одним рядком. Вміст їхніх викликів в архів не
    /// потрапляє навмисно — він роздував би його на порядки.
    private var toolLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Text(Self.summarize(message.tools))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            // Рідко, але буває: увесь турн — самі інструменти, без
            // жодного тексту. Тоді час має показатись хоч тут.
            if message.text.isEmpty, let seconds = message.replySeconds {
                Text("· \(Format.duration(seconds))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 2)
    }

    /// ["Bash","Bash","Read"] -> "Bash ×2 · Read".
    /// Порядок збережено: видно, чим саме вона займалась по черзі.
    static func summarize(_ tools: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]

        for tool in tools {
            if counts[tool] == nil { order.append(tool) }
            counts[tool, default: 0] += 1
        }

        return order
            .map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }
            .joined(separator: " · ")
    }
}
