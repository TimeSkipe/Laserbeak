import SwiftUI
import AppKit
import Combine

// Острів біля вирізу екрана — як Dynamic Island на айфоні.
//
// Обабіч вирізу MacBook, у мертвій зоні меню-бару, — значки активних
// агентів, а праворуч — скільки з них чекає на тебе. Помаранчеве означає,
// що хтось чекає дозволу. Клік розгортає острів униз: хто саме чекає і хто
// працює. Клік по рядку відкриває редактор, звідки сесію запущено.
//
// Вікно — панель без рамки над меню-баром (рівень statusBar). Вона не
// забирає фокус і є на всіх робочих столах. Тільки на екрані з вирізом:
// без нього острову нема до чого прилягти.
//
// Жодної безкінечної анімації: у SwiftUI будь-яка така щокадру
// перемальовує все вікно (docs/decisions.md). Помаранчеве — статичний колір,
// анімується лише разове розгортання.

enum IslandMetrics {
    /// Ширина «крила» обабіч вирізу. Вузьке навмисно: ліворуч від вирізу
    /// бувають меню програм, праворуч — значки меню-бару.
    static let wing: CGFloat = 38
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 2
    static let maxRows = 6
    static let footerHeight: CGFloat = 26
    static let expandedWidth: CGFloat = 380
    static let listTop: CGFloat = 6
    static let listBottom: CGFloat = 10
}

/// Де виріз на цьому маку. macOS 12+ віддає вільні шматки меню-бару
/// ліворуч і праворуч від нього; виріз — те, що між ними, по центру.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var height: CGFloat

    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = screen.frame.width - left - right
            guard width > 0, width < screen.frame.width / 2 else { continue }
            return NotchGeometry(screenFrame: screen.frame, notchWidth: width, height: screen.safeAreaInsets.top)
        }
        return nil
    }
}

@MainActor
final class IslandModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let project: String
        let icon: String
        let status: SessionStatus
        /// Bundle id редактора, з якого запущено сесію; порожньо — невідомо.
        let editor: String
    }

    /// Уже відсортовані: спершу ті, що чекають на тебе.
    @Published var items: [Item] = []
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var height: CGFloat = 32

    var waitingForPermission: Int { items.filter { $0.status == .needsInput }.count }
    var working: Int { items.filter { $0.status == .working }.count }

    var visibleItems: ArraySlice<Item> { items.prefix(IslandMetrics.maxRows) }
    var hiddenCount: Int { max(0, items.count - IslandMetrics.maxRows) }

    var collapsedSize: CGSize {
        CGSize(width: notchWidth + 2 * IslandMetrics.wing, height: height)
    }

    var expandedSize: CGSize {
        let rows = CGFloat(visibleItems.count)
        let list = IslandMetrics.listTop
            + rows * IslandMetrics.rowHeight
            + max(0, rows - 1) * IslandMetrics.rowSpacing
            + (hiddenCount > 0 ? IslandMetrics.footerHeight : 0)
            + IslandMetrics.listBottom
        return CGSize(width: max(collapsedSize.width, IslandMetrics.expandedWidth), height: height + list)
    }
}

/// Панель над меню-баром: без рамки, без фокусу, на всіх робочих столах.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Перший клік по неактивній панелі має спрацювати одразу, а не лише
/// «розбудити» її.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandController {
    static let shared = IslandController()

    private let model = IslandModel()
    private var panel: IslandPanel?
    private var geometry: NotchGeometry?
    private var subscriptions = Set<AnyCancellable>()
    private var outsideClicks: Any?
    private weak var client: DaemonClient?

    /// Запускає той, хто живе весь час роботи програми, — підпис у меню-барі.
    func start(client: DaemonClient) {
        guard self.client == nil else { return }
        self.client = client

        client.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &subscriptions)

        // Підключили чи відключили монітор, закрили кришку — виріз міг
        // зникнути або переїхати.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply(self?.client?.state) }
            .store(in: &subscriptions)
    }

    func toggle() {
        model.expanded ? collapse() : expand()
    }

    // ------------------------------------------------------------ стан

    private func apply(_ state: DaemonState?) {
        guard let state, state.islandEnabled, let geometry = NotchGeometry.current() else {
            hide()
            return
        }

        let items = Self.items(from: state)
        guard !items.isEmpty else {
            hide()
            return
        }

        self.geometry = geometry
        if model.notchWidth != geometry.notchWidth { model.notchWidth = geometry.notchWidth }
        if model.height != geometry.height { model.height = geometry.height }
        if model.items != items { model.items = items }

        show()
        place()
    }

    private static func items(from state: DaemonState) -> [IslandModel.Item] {
        var projectOf: [String: Project] = [:]
        for project in state.projects {
            for session in project.sessions { projectOf[session.sid] = project }
        }

        return state.sortedSessions.map { session in
            let project = projectOf[session.sid]
            return IslandModel.Item(
                id: session.sid,
                title: session.title,
                project: session.project,
                icon: project?.iconName ?? Lucide.fallback,
                status: session.state,
                editor: project?.editorBundleId ?? ""
            )
        }
    }

    // ------------------------------------------------------------ вікно

    private func show() {
        if panel == nil {
            let panel = IslandPanel()
            panel.contentView = IslandHostingView(rootView: IslandView(
                model: model,
                onToggle: { [weak self] in self?.toggle() },
                onOpen: { [weak self] item in self?.open(item) },
                onOpenAll: { [weak self] in self?.openAll() }
            ))
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        collapse()
        panel?.orderOut(nil)
    }

    /// Панель завжди рівно такого розміру, як острів: інакше прозорі краї
    /// забирали б кліки в меню-бару під собою.
    private func place(expanded: Bool? = nil) {
        guard let panel, let geometry else { return }
        let size = (expanded ?? model.expanded) ? model.expandedSize : model.collapsedSize
        let frame = CGRect(
            x: geometry.screenFrame.midX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func expand() {
        guard panel != nil else { return }
        // Спершу розсуваємо панель, потім острів у ній: так анімація не
        // впирається в краї вікна.
        place(expanded: true)

        // Новий розмір панелі SwiftUI мусить прийняти ще до анімації.
        // Інакше перенесення острова в центр ширшої панелі потрапляє в ту
        // саму анімацію: острів стартує від лівого краю й росте вправо, і
        // значки на мить їдуть убік (docs/decisions.md).
        panel?.contentView?.layoutSubtreeIfNeeded()

        // Клік будь-де поза островом — згорнути. Глобальний монітор бачить
        // кліки в інших програмах; доступу до клавіатури він не просить.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in IslandController.shared.collapse() }
        }

        DispatchQueue.main.async { [weak self] in
            // Встигли згорнути ще до цього такту — не розгортаємо.
            guard let self, self.outsideClicks != nil else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.model.expanded = true }
        }
    }

    func collapse() {
        if let outsideClicks {
            NSEvent.removeMonitor(outsideClicks)
            self.outsideClicks = nil
        }
        guard model.expanded else {
            // Розгортання ще не почалось, а панель уже розсунута — повертаємо
            // її одразу, щоб прозорі краї не забирали кліки.
            place()
            return
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.expanded = false }
        // Панель стискаємо, коли острів уже згорнувся.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.place()
        }
    }

    // ------------------------------------------------------------ дії

    private func open(_ item: IslandModel.Item) {
        collapse()
        if !item.editor.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.editor) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            AppRouter.shared.show(.sessions)
        }
    }

    private func openAll() {
        collapse()
        AppRouter.shared.show(.sessions)
    }
}

// MARK: - Вигляд

/// Прямокутник із пласким верхом — він прилягає до краю екрана — і
/// заокругленим низом, як сам виріз.
struct IslandShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0),
            style: .continuous
        ).path(in: rect)
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    let onToggle: () -> Void
    let onOpen: (IslandModel.Item) -> Void
    let onOpenAll: () -> Void

    var body: some View {
        let size = model.expanded ? model.expandedSize : model.collapsedSize
        let shape = IslandShape(radius: model.expanded ? 22 : 10)

        VStack(spacing: 0) {
            header
            if model.expanded {
                list
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(Color.black))
        .overlay {
            // Хтось чекає дозволу — острів обведено помаранчевим. Статично.
            if model.waitingForPermission > 0 {
                shape.stroke(Color.orange.opacity(0.85), lineWidth: 1.5)
            }
        }
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Чорне тло — тож і кольори системи як для темної теми.
        .environment(\.colorScheme, .dark)
    }

    // ------------------------------------------------------------ шапка

    /// Рядок на висоті меню-бару: крило — виріз — крило. По центру нічого
    /// не малюємо: там камера.
    private var header: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: IslandMetrics.wing)
            Color.clear
                .frame(width: model.notchWidth)
            rightWing
                .frame(width: IslandMetrics.wing)
        }
        .frame(height: model.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    /// Значки найтерміновіших агентів — іконка проєкту в кольорі стану.
    private var leftWing: some View {
        HStack(spacing: 3) {
            ForEach(model.items.prefix(2)) { item in
                LucideIcon(name: item.icon, size: 13)
                    .foregroundStyle(item.status.color)
            }
        }
    }

    /// Скільки чекає дозволу; якщо ніхто — скільки працює; інакше — скільки всього.
    private var rightWing: some View {
        HStack(spacing: 3) {
            if model.waitingForPermission > 0 {
                Image(systemName: "hand.raised.fill")
                Text(verbatim: "\(model.waitingForPermission)")
            } else if model.working > 0 {
                Image(systemName: "circle.dotted")
                Text(verbatim: "\(model.working)")
            } else {
                Text(verbatim: "\(model.items.count)")
            }
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(model.waitingForPermission > 0 ? Color.orange
                         : model.working > 0 ? Color.blue : Color.secondary)
    }

    // ------------------------------------------------------------ список

    private var list: some View {
        VStack(spacing: IslandMetrics.rowSpacing) {
            ForEach(model.visibleItems) { item in
                Button { onOpen(item) } label: { IslandRow(item: item) }
                    .buttonStyle(.plain)
            }
            if model.hiddenCount > 0 {
                Button(action: onOpenAll) {
                    Text("Усі сесії — у вікні Laserbeak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .frame(height: IslandMetrics.footerHeight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, IslandMetrics.listTop)
        .padding(.bottom, IslandMetrics.listBottom)
    }
}

struct IslandRow: View {
    let item: IslandModel.Item

    var body: some View {
        HStack(spacing: 10) {
            IconTile(icon: item.icon, color: item.status.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: item.project)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(text: item.status.title, color: item.status.color)
        }
        .padding(.horizontal, 8)
        .frame(height: IslandMetrics.rowHeight)
        .background(
            item.status == .needsInput ? Color.orange.opacity(0.16) : Color.white.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}
