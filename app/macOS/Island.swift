import SwiftUI
import AppKit
import Combine

// Острів біля вирізу екрана — як Dynamic Island на айфоні.
//
// На екрані з вирізом (MacBook) — чорний острів довкола вирізу: ліворуч
// знаки агентів (Claude, Codex…), праворуч — скільки з них чекає дозволу
// або працює. Помаранчеве — хтось чекає дозволу. На екрані без вирізу
// (зовнішній монітор) — вузька смужка посеред меню-бару: що робить сесія
// й скільки триває її хід.
//
// Клік розгортає список: хто чекає, хто працює, що саме робить і скільки
// памʼяті тримає. Клік по рядку відкриває редактор сесії, рядок унизу —
// вікно Laserbeak, клік деінде згортає.
//
// Кожен екран отримує свою панель без рамки над меню-баром (рівень
// statusBar): вона не забирає фокус і є на всіх робочих столах. Розміри —
// від висоти меню-бару цього екрана, тож острів однаково сидить на
// MacBook Air і Pro, у масштабованих режимах і на будь-якому моніторі.
//
// Жодної безкінечної анімації: у SwiftUI будь-яка така щокадру
// перемальовує все вікно (docs/decisions.md). Час ходу оновлюється раз на
// секунду, і лише поки сесія працює.

// MARK: - Розміри

/// Усі розміри — від висоти меню-бару на цьому екрані, а не зашиті пікселі.
struct IslandMetrics: Equatable {
    var bar: CGFloat

    /// Знак агента в крилі.
    var icon: CGFloat { (bar * 0.56).rounded() }
    /// Між знаками.
    var gap: CGFloat { max(3, (bar * 0.12).rounded()) }
    /// Від вирізу до вмісту крила.
    var inner: CGFloat { max(5, (bar * 0.22).rounded()) }
    /// Від вмісту крила до краю острова.
    var outer: CGFloat { max(7, (bar * 0.3).rounded()) }
    /// Те саме, коли праворуч тісно: далі однаково прозорі поля значка
    /// меню-бару, тож візуально відступ лишається.
    var outerTight: CGFloat { max(4, (bar * 0.14).rounded()) }
    /// Найширше ліве крило: далі вже меню програм.
    var leftMax: CGFloat { (bar * 3).rounded() }

    var font: CGFloat { max(10, (bar * 0.36).rounded()) }
    var rowHeight: CGFloat { max(40, (bar * 1.35).rounded()) }
    var rowIcon: CGFloat { (rowHeight * 0.55).rounded() }
    var rowSpacing: CGFloat { 2 }
    var listTop: CGFloat { 6 }
    var listBottom: CGFloat { 10 }
    var footerHeight: CGFloat { max(22, (bar * 0.8).rounded()) }
    var expandedWidth: CGFloat { max(340, (bar * 12.5).rounded()) }
    var stripHeight: CGFloat { max(16, bar - 6) }
    var stripMaxWidth: CGFloat { max(260, (bar * 13).rounded()) }
    /// Наскільки обведений острів опускається нижче вирізу. Виріз рівно
    /// такої висоти, як меню-бар, тож без цього нижня лінія обідка лягала б
    /// під нього й посередині зникала.
    var rim: CGFloat { max(3, (bar * 0.1).rounded()) }

    static let maxRows = 6
    static let maxAgents = 3

    /// Ширина числа на острові — тим самим шрифтом, яким його малюємо.
    func countWidth(_ value: Int) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: self.font, weight: .semibold)
        return ("\(value)" as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    var handWidth: CGFloat { (font * 1.15).rounded(.up) }
}

// MARK: - Екрани

/// Де на конкретному екрані жити острову.
struct ScreenSpot: Equatable {
    enum Style: Equatable {
        /// Острів довкола вирізу заданої ширини.
        case notch(width: CGFloat)
        /// Вузька смужка посеред меню-бару — на екрані без вирізу.
        case strip
    }

    let id: CGDirectDisplayID
    /// Екран у координатах AppKit.
    let frame: CGRect
    /// Висота меню-бару на цьому екрані.
    let bar: CGFloat
    let style: Style
    /// Лівий край найближчого праворуч значка меню-бару (глобальний x),
    /// або nil, якщо там вільно.
    let firstItemX: CGFloat?

    var metrics: IslandMetrics { IslandMetrics(bar: bar) }

    /// Усі екрани, на яких є меню-бар.
    static func all() -> [ScreenSpot] {
        let items = statusItems()
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0

        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }

            let frame = screen.frame
            let notched = screen.safeAreaInsets.top > 0
            let bar = notched ? screen.safeAreaInsets.top : frame.maxY - screen.visibleFrame.maxY
            // Меню-бару тут немає (ховається або один на всі екрани) — і
            // острову нема де стати.
            guard bar > 0 else { return nil }

            var style = Style.strip
            var threshold = frame.midX
            if notched {
                // macOS 12+ віддає вільні шматки меню-бару ліворуч і праворуч
                // від вирізу; сам виріз — те, що між ними, по центру.
                let width = frame.width
                    - (screen.auxiliaryTopLeftArea?.width ?? 0)
                    - (screen.auxiliaryTopRightArea?.width ?? 0)
                if width > 0, width < frame.width / 2 {
                    style = .notch(width: width)
                    threshold = frame.midX + width / 2 - 2
                }
            }

            // Значки меню-бару в координатах CoreGraphics: y рахується
            // згори від основного екрана.
            let top = primaryTop - frame.maxY
            let first = items
                .filter { abs($0.minY - top) < 2 && $0.minX >= threshold && $0.maxX <= frame.maxX + 1 }
                .map(\.minX)
                .min()

            return ScreenSpot(id: number.uint32Value, frame: frame, bar: bar, style: style, firstItemX: first)
        }
    }

    /// Вікна значків меню-бару (рівень statusWindow), крім наших власних.
    /// Їхні рамки видно без дозволу на запис екрана — лише назви приховані.
    private static func statusItems() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let me = ProcessInfo.processInfo.processIdentifier
        let level = Int(CGWindowLevelForKey(.statusWindow))
        return list.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == level,
                  (window[kCGWindowOwnerPID as String] as? Int32) != me,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return rect
        }
    }
}

// MARK: - Дані

struct IslandItem: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let agent: String
    let projectIcon: String
    /// Назва кольору з палітри; порожнє — типовий.
    let projectColor: String
    let status: SessionStatus
    /// Що робить просто зараз: «редагує server.js». Порожнє — невідомо.
    let activity: String
    /// Памʼять агента разом із його процесами: «1,6 ГБ». Порожнє — невідомо.
    let memory: String
    /// Коли почався поточний хід, epoch ms.
    let turnStartedAt: Double?
    let lastTurnSeconds: Double?
    /// Bundle id редактора, з якого запущено сесію; порожньо — невідомо.
    let editor: String

    /// Скільки триває поточний хід, станом на `date`.
    func elapsed(at date: Date) -> Int? {
        guard status == .working, let start = turnStartedAt else { return nil }
        return max(0, Int(date.timeIntervalSince1970 - start / 1000))
    }

    /// Коротко, що з сесією: що робить, або її стан.
    var statusLine: String {
        status == .working && !activity.isEmpty ? activity : status.title
    }

    /// Проєкт, а поруч — що робить. У сесії, що чекає дозволу, остання дія —
    /// саме те, на що вона просить дозволу: «виконує: Restart daemon».
    /// Хто чекає дозволу — лише дія: на неї й просять дозволу, і обрізати
    /// її назвою проєкту шкода (проєкт видно з іконки в куточку).
    var subtitle: String {
        if status == .needsInput, !activity.isEmpty { return activity }
        return activity.isEmpty || status != .working ? project : "\(project) · \(activity)"
    }
}

/// Час ходу цифрами — однаково всіма мовами: 3:42 або 1:02:10.
enum Clock {
    static func text(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var spot: ScreenSpot
    /// Уже відсортовані: спершу ті, що чекають дозволу, потім ті, що працюють.
    @Published var items: [IslandItem] = []
    @Published var expanded = false
    /// Розгорнуто саме тому, що хтось просить дозволу: у списку — лише ті,
    /// хто чекає. Звичайне розгортання кліком показує всіх.
    @Published var alert = false
    /// Не ховати від кліку деінде: тривогу легко проґавити, тож вона чекає
    /// відповіді агентові або кліку по самому острову.
    var pinned = false
    /// Панель зараз розміру розгорнутого острова (острів у ній ще може бути
    /// згорнутим — перед анімацією й одразу після неї).
    @Published var panelExpanded = false
    /// Ширина смужки — під її вміст, але не ширше, ніж дозволяє меню-бар.
    @Published var stripWidth: CGFloat = 0

    init(spot: ScreenSpot) {
        self.spot = spot
    }

    var metrics: IslandMetrics { spot.metrics }
    var isNotch: Bool { if case .notch = spot.style { true } else { false } }
    var notchWidth: CGFloat { if case .notch(let width) = spot.style { width } else { 0 } }

    var waitingForPermission: Int { items.filter { $0.status == .needsInput }.count }
    var working: Int { items.filter { $0.status == .working }.count }

    /// Число на острові: скільки чекає дозволу; якщо ніхто — скільки
    /// працює; інакше — скільки всього.
    var count: Int {
        waitingForPermission > 0 ? waitingForPermission : working > 0 ? working : items.count
    }

    /// Агенти, що зараз є, — кожен один раз, у порядку терміновості.
    var agents: [String] {
        var seen = Set<String>()
        return items.compactMap { seen.insert($0.agent).inserted ? $0.agent : nil }
    }

    var waitingItems: [IslandItem] { items.filter { $0.status == .needsInput } }

    /// Що в розгорнутому списку: при тривозі — хто чекає дозволу, інакше — всі.
    var listedItems: ArraySlice<IslandItem> {
        alert ? waitingItems.prefix(IslandMetrics.maxRows) : items.prefix(IslandMetrics.maxRows)
    }

    // ------------------------------------------------------------ крила

    /// Скільки вільно праворуч від вирізу до першого значка меню-бару.
    var rightRoom: CGFloat {
        let notchRight = spot.frame.midX + notchWidth / 2
        return spot.firstItemX.map { $0 - notchRight - 3 } ?? .greatestFiniteMagnitude
    }

    /// Праве крило: число з відступами від вирізу й від краю острова, а
    /// помаранчева рука — лише якщо вміщається. Праворуч від вирізу
    /// бувають значки меню-бару, налазити на них не можна. Тісно — спершу
    /// вужчий відступ до краю острова; тісно навіть так — крила немає,
    /// число переїжджає ліворуч.
    var right: (width: CGFloat, hand: Bool) {
        let m = metrics
        let digits = m.countWidth(count)
        let withHand = m.inner + m.handWidth + 3 + digits + m.outer
        let plain = m.inner + digits + m.outer
        let tight = m.inner + digits + m.outerTight
        if waitingForPermission > 0, withHand <= rightRoom { return (withHand, true) }
        if plain <= rightRoom { return (plain, false) }
        if tight <= rightRoom { return (tight, false) }
        return (0, false)
    }

    var countOnLeft: Bool { right.width == 0 }

    /// Ліве крило: знаки агентів у повний розмір. Ліворуч від вирізу
    /// місця більше, тож крила різні — острів не мусить бути симетричним.
    var left: (width: CGFloat, agents: [String]) {
        let m = metrics
        let countPart = countOnLeft ? m.gap + m.countWidth(count) : 0
        func width(_ n: Int) -> CGFloat {
            m.outer + CGFloat(n) * m.icon + CGFloat(max(0, n - 1)) * m.gap + countPart + m.inner
        }
        var shown = Array(agents.prefix(IslandMetrics.maxAgents))
        while shown.count > 1, width(shown.count) > m.leftMax { shown.removeLast() }
        return (width(shown.count), shown)
    }

    // ------------------------------------------------------------ розміри

    var headerHeight: CGFloat { isNotch ? spot.bar : metrics.stripHeight }

    /// Обведений острів біля вирізу нижчий за виріз на `rim`: вміст лишається
    /// в меню-барі, а нижня лінія обідка — під вирізом, де її видно.
    var collapsedSize: CGSize {
        isNotch
            ? CGSize(width: left.width + notchWidth + right.width,
                     height: spot.bar + (waitingForPermission > 0 ? metrics.rim : 0))
            : CGSize(width: stripWidth, height: metrics.stripHeight)
    }

    var expandedSize: CGSize {
        let m = metrics
        let rows = CGFloat(listedItems.count)
        let list = m.listTop
            + rows * m.rowHeight
            + max(0, rows - 1) * m.rowSpacing
            + m.footerHeight
            + m.listBottom
        // Розгорнутий острів — по центру вирізу, тож кожна половина має
        // вмістити ширше з крил.
        let width = isNotch
            ? max(m.expandedWidth, notchWidth + 2 * max(left.width, right.width))
            : max(stripWidth, m.expandedWidth)
        return CGSize(width: width, height: headerHeight + list)
    }

    /// Де згорнутий острів стоїть у розсунутій панелі: виріз не рухається,
    /// тож крило ліворуч від нього — там само, де й завжди.
    var collapsedOffset: CGFloat {
        isNotch
            ? (expandedSize.width - notchWidth) / 2 - left.width
            : (expandedSize.width - stripWidth) / 2
    }

    /// Острів прилягає до краю екрана — верх пласкі кути. Смужка висить у
    /// меню-барі — заокруглена вся.
    var shape: IslandShape {
        let scale = spot.bar / 32
        if isNotch {
            return IslandShape(top: 0, bottom: expanded ? 22 : (10 * scale).rounded())
        }
        return IslandShape(top: expanded ? 14 : metrics.stripHeight / 2,
                           bottom: expanded ? 14 : metrics.stripHeight / 2)
    }
}

// MARK: - Вікно

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

    /// Острів на одному екрані.
    private final class Surface {
        let panel = IslandPanel()
        let model: IslandModel

        init(model: IslandModel) {
            self.model = model
        }
    }

    private var surfaces: [CGDirectDisplayID: Surface] = [:]
    private var subscriptions = Set<AnyCancellable>()
    /// Сесії, про чий запит дозволу острів уже сповістив розгортанням.
    /// Новий запит (сесії немає в цьому списку) — розгортаємо знову.
    private var alerted = Set<String>()
    private var outsideClicks: Any?
    private weak var client: DaemonClient?

    /// Запускає той, хто живе весь час роботи програми, — підпис у меню-барі.
    func start(client: DaemonClient) {
        guard self.client == nil else { return }
        self.client = client

        // Стан приходить кожні дві секунди — заразом перемірюємо й вільне
        // місце в меню-барі: значки там зʼявляються й зникають.
        client.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &subscriptions)

        // Підключили чи відключили монітор, закрили кришку — екрани інші.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply(self?.client?.state) }
            .store(in: &subscriptions)
    }

    // ------------------------------------------------------------ стан

    private func apply(_ state: DaemonState?) {
        guard let state, state.islandEnabled else {
            hideAll()
            return
        }

        let items = Self.items(from: state)
        let spots = ScreenSpot.all()
        let present = Set(spots.map(\.id))

        for (id, surface) in surfaces where !present.contains(id) {
            surface.panel.orderOut(nil)
            surfaces[id] = nil
        }

        for spot in spots {
            let surface = surfaces[spot.id] ?? makeSurface(spot)
            let model = surface.model
            if model.spot != spot { model.spot = spot }
            if model.items != items { model.items = items }

            if !model.isNotch {
                let width = stripWidth(for: model)
                if model.stripWidth != width { model.stripWidth = width }
            }

            let visible = !items.isEmpty && (model.isNotch || model.stripWidth > 0)
            if visible {
                surface.panel.orderFrontRegardless()
                place(surface)
            } else {
                model.expanded = false
                model.alert = false
                surface.panel.orderOut(nil)
            }
        }

        alertIfNeeded(items)
    }

    /// Хтось новий просить дозволу — острів сам розгортається й показує, хто
    /// саме: помаранчевий обідок легко проґавити. І не ховається від кліку
    /// деінде — клікаєш постійно, і тривога зникала б непоміченою. Ховається,
    /// щойно відповідь отримано (демон бачить її в транскрипті), або від
    /// кліку по самому острову.
    private func alertIfNeeded(_ items: [IslandItem]) {
        let waiting = Set(items.filter { $0.status == .needsInput }.map(\.id))
        let fresh = !waiting.subtracting(alerted).isEmpty
        alerted = waiting

        let shown = surfaces.values.filter { $0.panel.isVisible }
        if fresh {
            // Список, уже відкритий кліком, лишається як є, але теж
            // закріплюється — інакше перший же клік деінде сховав би і запит.
            for surface in shown where surface.model.panelExpanded { surface.model.pinned = true }
            let closed = shown.filter { !$0.model.panelExpanded }
            if !closed.isEmpty { open(closed, alert: true) }
            updateOutsideClicks()
        } else if waiting.isEmpty {
            // Відповідь отримано: тривогу згортаємо, а відкритий людиною
            // список лише відкріплюємо.
            collapse(shown.filter { $0.model.alert })
            for surface in shown where !surface.model.alert { surface.model.pinned = false }
            updateOutsideClicks()
        }
    }

    /// Спершу ті, що чекають на тебе, потім ті, що працюють; серед рівних —
    /// найсвіжіші.
    private static func items(from state: DaemonState) -> [IslandItem] {
        var projectOf: [String: Project] = [:]
        for project in state.projects {
            for session in project.sessions { projectOf[session.sid] = project }
        }

        func rank(_ status: SessionStatus) -> Int {
            switch status {
            case .needsInput: 0
            case .working:    1
            case .waiting:    2
            case .idle:       3
            }
        }
        func freshness(_ s: Session) -> Double {
            max(s.activity?.at ?? 0, s.turnStartedAt ?? 0, s.since)
        }

        return state.sessions
            .sorted {
                rank($0.state) != rank($1.state)
                    ? rank($0.state) < rank($1.state)
                    : freshness($0) > freshness($1)
            }
            .map { session in
                let project = projectOf[session.sid]
                return IslandItem(
                    id: session.sid,
                    title: session.title,
                    project: session.project,
                    agent: session.agent,
                    projectIcon: project?.iconName ?? Lucide.fallback,
                    projectColor: project?.settings.color ?? "",
                    status: session.state,
                    activity: session.activity?.text ?? "",
                    memory: session.memoryText ?? "",
                    turnStartedAt: session.turnStartedAt,
                    lastTurnSeconds: session.lastTurnSeconds,
                    editor: project?.editorBundleId ?? ""
                )
            }
    }

    /// Смужка — під свій вміст, але не ширше, ніж дозволяє меню-бар:
    /// праворуч від неї значки, і налазити на них не можна. Зовсім тісно — 0,
    /// смужки не буде.
    private func stripWidth(for model: IslandModel) -> CGFloat {
        let m = model.metrics
        guard let item = model.items.first else { return 0 }

        var cap = m.stripMaxWidth
        if let x = model.spot.firstItemX { cap = min(cap, 2 * (x - 8 - model.spot.frame.midX)) }
        guard cap >= m.stripHeight * 4 else { return 0 }

        let line = StripLine(item: item, more: model.items.count - 1, metrics: m)
            .environment(\.colorScheme, .dark)
            .fixedSize()
        // Запас на час ходу: цифри ростуть, а смужка не має смикатись щосекунди.
        let ideal = NSHostingView(rootView: line).fittingSize.width + m.font * 1.5
        return min(cap, max(m.stripHeight * 4, ideal.rounded(.up)))
    }

    // ------------------------------------------------------------ вікна

    private func makeSurface(_ spot: ScreenSpot) -> Surface {
        let surface = Surface(model: IslandModel(spot: spot))
        let id = spot.id
        surface.panel.contentView = IslandHostingView(rootView: IslandView(
            model: surface.model,
            onToggle: { [weak self] in self?.toggle(id) },
            onOpen: { [weak self] item in self?.open(item) },
            onOpenAll: { [weak self] in self?.openAll() }
        ))
        surfaces[id] = surface
        return surface
    }

    private func hideAll() {
        collapseAll()
        for surface in surfaces.values { surface.panel.orderOut(nil) }
    }

    /// Панель завжди рівно такого розміру, як острів: інакше прозорі краї
    /// забирали б кліки в меню-бару під собою.
    private func place(_ surface: Surface, expanded: Bool? = nil) {
        let model = surface.model
        let spot = model.spot
        let wide = expanded ?? model.expanded
        let size = wide ? model.expandedSize : model.collapsedSize

        // Згорнутий острів біля вирізу стоїть від лівого краю крила — крила
        // різні; розгорнутий і смужка — по центру.
        let x = model.isNotch && !wide
            ? spot.frame.midX - model.notchWidth / 2 - model.left.width
            : spot.frame.midX - size.width / 2
        // Острів прилягає до краю екрана; смужка — посередині меню-бару.
        let inset = model.isNotch ? 0 : ((spot.bar - model.metrics.stripHeight) / 2).rounded()
        let frame = CGRect(x: x.rounded(), y: spot.frame.maxY - inset - size.height,
                           width: size.width, height: size.height)

        guard surface.panel.frame != frame || model.panelExpanded != wide else { return }
        model.panelExpanded = wide
        surface.panel.setFrame(frame, display: true)
        // Острів у панелі мусить стати на нове місце в тому ж такті, що й
        // сама панель, — інакше на мить видно стрибок.
        surface.panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Клік по острову: відкритий — згорнути (і тривогу теж), закритий —
    /// показати всі сесії.
    func toggle(_ id: CGDirectDisplayID) {
        guard let surface = surfaces[id] else { return }
        if surface.model.expanded {
            collapseAll()
        } else {
            collapseAll()
            open([surface], alert: false)
        }
    }

    private func open(_ list: [Surface], alert: Bool) {
        // Спершу розсуваємо панель, а острів у ній лишається згорнутим на
        // своєму місці. Анімація — наступним тактом: якщо зміна розміру
        // панелі потрапить у ту саму анімацію, значки на мить поїдуть убік
        // (docs/decisions.md).
        for surface in list {
            surface.model.alert = alert
            surface.model.pinned = alert
            place(surface, expanded: true)
        }
        updateOutsideClicks()

        DispatchQueue.main.async {
            // Встигли згорнути ще до цього такту — панель уже стиснута, не
            // розгортаємо.
            let still = list.filter { $0.model.panelExpanded && !$0.model.expanded }
            guard !still.isEmpty else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                for surface in still { surface.model.expanded = true }
            }
        }
    }

    func collapseAll() {
        collapse(Array(surfaces.values))
    }

    /// Клік деінде ховає лише незакріплене: список, відкритий людиною. Тривогу
    /// — ні.
    private func outsideClick() {
        collapse(surfaces.values.filter { $0.model.expanded && !$0.model.pinned })
    }

    /// Глобальний монітор кліків — лише доки відкрито щось незакріплене.
    /// Він бачить кліки в інших програмах; доступу до клавіатури не просить.
    private func updateOutsideClicks() {
        let needed = surfaces.values.contains { $0.model.panelExpanded && !$0.model.pinned }
        if needed, outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                Task { @MainActor in IslandController.shared.outsideClick() }
            }
        } else if !needed, let outsideClicks {
            NSEvent.removeMonitor(outsideClicks)
            self.outsideClicks = nil
        }
    }

    private func collapse(_ list: [Surface]) {
        for surface in list {
            guard surface.model.expanded else {
                // Розгортання ще не почалось, а панель уже могла розсунутись —
                // повертаємо одразу, щоб прозорі краї не забирали кліки.
                surface.model.alert = false
                surface.model.pinned = false
                place(surface)
                continue
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { surface.model.expanded = false }
            // Панель стискаємо, коли острів уже згорнувся.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self, !surface.model.expanded else { return }
                surface.model.alert = false
                surface.model.pinned = false
                self.place(surface)
                self.updateOutsideClicks()
            }
        }
        updateOutsideClicks()
    }

    // ------------------------------------------------------------ дії

    private func open(_ item: IslandItem) {
        collapseAll()
        if !item.editor.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.editor) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            AppRouter.shared.show(.sessions)
        }
    }

    private func openAll() {
        collapseAll()
        AppRouter.shared.show(.sessions)
    }
}

// MARK: - Вигляд

/// Прямокутник із окремими радіусами згори й знизу: острів біля вирізу
/// має пласкі верхні кути, смужка заокруглена вся.
struct IslandShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top),
            style: .continuous
        ).path(in: rect)
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    let onToggle: () -> Void
    let onOpen: (IslandItem) -> Void
    let onOpenAll: () -> Void

    var body: some View {
        let size = model.expanded ? model.expandedSize : model.collapsedSize
        let shape = model.shape

        VStack(spacing: 0) {
            header
                .frame(height: model.headerHeight)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
            if model.expanded {
                list
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(Color.black))
        .overlay {
            // Хтось чекає дозволу — острів обведено помаранчевим. Статично.
            // Біля вирізу — без верхньої лінії: там край екрана, а посередині
            // сам виріз. Її піднято над островом, і clipShape її відрізає.
            if model.waitingForPermission > 0 {
                shape.stroke(Color.orange.opacity(0.85), lineWidth: 1.5)
                    .padding(.top, model.isNotch ? -2 : 0)
            }
        }
        .clipShape(shape)
        // Згорнутий острів у розсунутій панелі — на своєму звичному місці.
        .offset(x: model.panelExpanded && !model.expanded ? model.collapsedOffset : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Чорне тло — тож і кольори системи як для темної теми.
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var header: some View {
        if model.isNotch {
            notchHeader
        } else {
            StripLine(item: model.items.first, more: model.items.count - 1, metrics: model.metrics)
                .frame(width: model.collapsedSize.width)
        }
    }

    /// Крило — виріз — крило. По центру нічого не малюємо: там камера.
    /// Вміст крил притиснуто до вирізу, тож коли острів розгортається, а
    /// крила ширшають, знаки й число лишаються на місці.
    private var notchHeader: some View {
        let m = model.metrics
        let width = model.expanded ? model.expandedSize.width : model.collapsedSize.width
        let half = (width - model.notchWidth) / 2
        let left = model.expanded ? half : model.left.width
        let right = model.expanded ? half : model.right.width

        return HStack(spacing: 0) {
            leftWing
                .padding(.trailing, m.inner)
                .frame(width: max(0, left), alignment: .trailing)
            Color.clear
                .frame(width: model.notchWidth)
            rightWing
                .padding(.leading, m.inner)
                .frame(width: max(0, right), alignment: .leading)
        }
    }

    /// Просто знаки агентів — Claude, Codex, — кожен один раз. Число —
    /// тут же, якщо праворуч від вирізу йому тісно.
    private var leftWing: some View {
        let m = model.metrics
        return HStack(spacing: m.gap) {
            ForEach(model.left.agents, id: \.self) { agent in
                AgentMark(agent: agent, size: m.icon)
            }
            if model.countOnLeft {
                countText
            }
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        if !model.countOnLeft {
            HStack(spacing: 3) {
                if model.right.hand {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: model.metrics.font, weight: .semibold))
                        .foregroundStyle(countColor)
                }
                countText
            }
        }
    }

    private var countText: some View {
        Text(verbatim: "\(model.count)")
            .font(.system(size: model.metrics.font, weight: .semibold).monospacedDigit())
            .foregroundStyle(countColor)
    }

    /// Помаранчеве — чекає дозволу, синє — працює, сіре — решта.
    private var countColor: Color {
        model.waitingForPermission > 0 ? .orange : model.working > 0 ? .blue : .secondary
    }

    private var list: some View {
        let m = model.metrics
        return VStack(spacing: m.rowSpacing) {
            ForEach(model.listedItems) { item in
                Button { onOpen(item) } label: { IslandRow(item: item, metrics: m) }
                    .buttonStyle(.plain)
            }
            // Завжди, а не лише коли рядків більше, ніж вміщається: це й
            // найкоротший шлях у вікно програми.
            Button(action: onOpenAll) {
                Text("Усі сесії — у вікні Laserbeak")
                    .font(.system(size: m.font - 1))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .frame(height: m.footerHeight)
        }
        .padding(.horizontal, 12)
        .padding(.top, m.listTop)
        .padding(.bottom, m.listBottom)
    }
}

/// Рядок смужки: знак агента, назва, що робить, скільки триває хід.
struct StripLine: View {
    let item: IslandItem?
    let more: Int
    let metrics: IslandMetrics

    var body: some View {
        HStack(spacing: 6) {
            if let item {
                AgentBadge(item: item, size: max(10, metrics.stripHeight - 6))
                Text(verbatim: item.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: item.statusLine)
                    .foregroundStyle(item.status == .needsInput ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.status == .working, item.turnStartedAt != nil {
                    // Раз на секунду, лише поки сесія працює.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: Clock.text(item.elapsed(at: context.date) ?? 0))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .layoutPriority(1)
                } else if item.status == .waiting, let seconds = item.lastTurnSeconds {
                    Text(verbatim: Format.duration(seconds))
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                if more > 0 {
                    Text(verbatim: "+\(more)")
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                }
            }
        }
        .font(.system(size: metrics.font))
        .foregroundStyle(.primary)
        .padding(.horizontal, (metrics.stripHeight * 0.5).rounded())
    }
}

/// Рядок розгорнутого острова: знак агента з іконкою проєкту, назва, що
/// робить; праворуч — стан, а під ним памʼять і час ходу.
struct IslandRow: View {
    let item: IslandItem
    let metrics: IslandMetrics

    var body: some View {
        HStack(spacing: 10) {
            AgentBadge(item: item, size: metrics.rowIcon)
                .padding(.trailing, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                    .font(.system(size: metrics.font + 1, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: item.subtitle)
                    .font(.system(size: metrics.font - 1))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                StatusPill(text: item.status.title, color: item.status.color)
                HStack(spacing: 6) {
                    if !item.memory.isEmpty {
                        Text(verbatim: item.memory)
                    }
                    if item.status == .working, item.turnStartedAt != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: Clock.text(item.elapsed(at: context.date) ?? 0))
                        }
                    }
                }
                .font(.system(size: metrics.font - 2).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: metrics.rowHeight)
        .background(
            item.status == .needsInput ? Color.orange.opacity(0.16) : Color.white.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

/// Знак агента (Claude, Codex, Gemini), а в куточку — іконка проєкту на
/// чорному кружечку з обідком кольору стану.
struct AgentBadge: View {
    let item: IslandItem
    let size: CGFloat

    var body: some View {
        let corner = max(8, (size * 0.62).rounded())
        AgentMark(agent: item.agent, size: size)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.black)
                    .overlay {
                        LucideIcon(name: item.projectIcon, size: (corner * 0.62).rounded())
                            .foregroundStyle(Palette.color(item.projectColor) ?? Color.white.opacity(0.85))
                    }
                    .overlay {
                        Circle().stroke(item.status.color, lineWidth: max(1, corner * 0.12))
                    }
                    .frame(width: corner, height: corner)
                    .offset(x: corner * 0.32, y: corner * 0.28)
            }
            .frame(width: size, height: size)
    }
}

/// Знак агента; для агента без знака — запасний значок.
struct AgentMark: View {
    let agent: String
    let size: CGFloat

    var body: some View {
        if AgentLogo.names.contains(agent) {
            AgentLogoShape(agent: agent)
                .fill(AgentLogo.color(agent) ?? Color.primary)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
