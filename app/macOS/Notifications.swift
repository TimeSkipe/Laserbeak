import Foundation
import UserNotifications
import AppKit
import SwiftUI

// Показ банерів від імені Laserbeak.
//
// Раніше це робив terminal-notifier — стороння програма, тож у Центрі
// сповіщень банери були підписані нею. Тепер їх показує сам застосунок:
// своя іконка, своє ім'я, своя група в налаштуваннях системи.
//
// Демон тримає чергу подій, а ми чекаємо на них одним довгим запитом,
// тому банер з'являється одразу, а не з затримкою опитування.

/// Власний лог у файл.
///
/// Коли програму запускає LaunchServices (через `open`), її stdout нікуди
/// не веде — ні в термінал, ні в лог launchd. Тому пишемо самі, поруч із
/// логом демона.
///
/// Помилки (`error`) лягають ще й у спільний з демоном errors.log — там
/// одним списком видно, що зламалось і в програмі, і в демоні.
enum AppLog {
    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".laserbeak")
    private static let url = dir.appendingPathComponent("app.log")
    private static let errorsURL = dir.appendingPathComponent("errors.log")

    /// Старше переїжджає в app.log.1 — один раз, без купи архівів.
    private static let limit: UInt64 = 2 * 1024 * 1024

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        // Інакше в системі з тайським чи японським календарем рік у лозі
        // був би не той.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        append("[\(stamp.string(from: Date()))] \(oneLine(message))\n", to: url)
        rotateIfNeeded()
    }

    /// Збій: у app.log і в errors.log, з позначкою, що це програма.
    static func error(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] ✖ програма: \(oneLine(message))\n"
        append(line, to: url)
        append(line, to: errorsURL)
        rotateIfNeeded()
    }

    /// Що саме не розібралось у відповіді демона. Розбір падає на одному
    /// полі, а гасне весь екран — тож без назви поля шукати нема за що.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }

        func path(_ context: DecodingError.Context, _ last: CodingKey? = nil) -> String {
            let keys = context.codingPath + (last.map { [$0] } ?? [])
            let text = keys.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }
                .joined()
            return text.isEmpty ? "корінь" : String(text.drop(while: { $0 == "." }))
        }

        switch decoding {
        case .keyNotFound(let key, let c):  return "немає ключа \(path(c, key))"
        case .typeMismatch(let t, let c):   return "не той тип у \(path(c)): чекали \(t)"
        case .valueNotFound(let t, let c):  return "порожнє значення у \(path(c)): чекали \(t)"
        case .dataCorrupted(let c):         return "зіпсовані дані у \(path(c)): \(c.debugDescription)"
        @unknown default:                   return error.localizedDescription
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
    }

    /// O_APPEND: у errors.log пишуть два процеси, і рядок має лягти в
    /// кінець, а не поверх чужого.
    private static func append(_ line: String, to file: URL) {
        let fd = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size > limit else { return }
        let old = dir.appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    // Живе стільки, скільки живе програма — незалежно від того, чи
    // відкрите вікно. Інакше банери зникали б після його закриття.
    static let shared = NotificationService()

    @Published private(set) var authorized = false
    @Published private(set) var lastError: String?

    /// Номер останньої показаної події. Переживає перезапуск програми,
    /// щоб після її відкриття не сипались старі банери.
    private var since: Int {
        get { UserDefaults.standard.integer(forKey: "notificationsSince") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsSince") }
    }

    private var listenTask: Task<Void, Never>?
    private var baseURL: URL?
    private var listenFailing = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func start(baseURL: URL?) {
        self.baseURL = baseURL
        requestAuthorization()

        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            await self?.listen()
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
    }

    // ------------------------------------------------------------ дозвіл

    /// Перечитати, чи дозволено нам показувати банери: людина могла
    /// змінити це в системних налаштуваннях, поки програма працювала.
    func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in self.authorized = allowed }
        }
    }

    private func requestAuthorization() {
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            AppLog.write("статус сповіщень: \(settings.authorizationStatus.rawValue)")

            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    AppLog.error("запит дозволу на сповіщення не вдався: \(error.localizedDescription)")
                } else {
                    AppLog.write("дозвіл на сповіщення: \(granted ? "надано" : "відмовлено")")
                }
                Task { @MainActor in
                    self?.authorized = granted
                    if let error { self?.lastError = error.localizedDescription }
                }
            }
        }
    }

    /// Показувати банер навіть тоді, коли вікно програми активне.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Клік по банеру відкриває редактор, з якого сесію запущено. Банер
    /// про нову версію — розділ «Оновлення» у вікні.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo

        if info["kind"] as? String == "update" {
            await MainActor.run { AppRouter.shared.show(.updates) }
            return
        }

        guard let bundleId = info["appBundle"] as? String, !bundleId.isEmpty else { return }

        await MainActor.run {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    // ------------------------------------------------------------ черга

    private func listen() async {
        while !Task.isCancelled {
            guard let baseURL else {
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            var components = URLComponents(
                url: baseURL.appendingPathComponent("events/wait"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "since", value: String(since))]

            guard let url = components?.url else { return }

            var request = URLRequest(url: url)
            // Трохи більше за таймаут на боці демона.
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let batch = try JSONDecoder().decode(NotificationBatch.self, from: data)

                // Відбирати нічого не треба: демон уже віддав саме те, чого
                // ми ще не бачили. Раніше тут стояв додатковий фільтр, і
                // після перезапуску демона перша подія через нього губилась.
                for item in batch.notifications {
                    show(item)
                }

                since = max(batch.seq, batch.notifications.map(\.seq).max() ?? 0)
                if listenFailing {
                    listenFailing = false
                    AppLog.write("черга сповіщень знову працює")
                }
            } catch {
                // Демон лежить або запит обірвався — почекаємо і спробуємо знову.
                // У лог — лише перший збій поспіль: демон може лежати годину,
                // а запит повторюється кожні три секунди.
                if !listenFailing {
                    listenFailing = true
                    AppLog.error("черга сповіщень (events/wait): \(AppLog.describe(error)) — банери не приходитимуть, доки демон не відповість")
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func show(_ item: DaemonNotification) {
        let content = UNMutableNotificationContent()
        content.title = item.session
        if !item.project.isEmpty { content.subtitle = item.project }
        content.body = item.message
        content.userInfo = ["appBundle": item.appBundle, "sid": item.sid, "kind": item.kind]

        if !item.sound.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(item.sound + ".aiff"))
        }

        // Сповіщення однієї сесії групуються разом; про сам Laserbeak —
        // окремо від усіх сесій.
        content.threadIdentifier = item.sid.isEmpty ? item.kind : item.sid

        // Іконка проєкту в його кольорі — банер упізнається, не читаючи текст.
        if let attachment = iconAttachment(for: item) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "laserbeak-\(item.seq)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                AppLog.error("банер [\(item.kind)] \(item.session) не показано: \(error.localizedDescription)")
                Task { @MainActor in self?.lastError = error.localizedDescription }
            } else {
                let look = item.icon.isEmpty ? "типова іконка" : item.icon
                AppLog.write("банер [\(item.kind)] \(item.session) · \(item.project) (\(look), \(item.color.isEmpty ? "типовий колір" : item.color))")
            }
        }
    }
}

// MARK: - Картинка для банера

extension NotificationService {
    /// Малює іконку проєкту в його кольорі, а в кутку — значок події,
    /// той самий, що в розділі «Сповіщення»: зелена галочка, помаранчева
    /// рука, пісочний годинник. Так банер каже і «чий», і «що сталося»
    /// ще до того, як прочитаєш текст.
    ///
    /// UNNotificationAttachment приймає лише файл, тому картинка щоразу
    /// пишеться в тимчасову теку. Файли дрібні, система прибирає їх сама.
    func iconAttachment(for item: DaemonNotification) -> UNNotificationAttachment? {
        let color = Palette.color(item.color) ?? .secondary
        let icon = item.icon.isEmpty ? Lucide.fallback : item.icon
        let kind = NotificationKind(id: item.kind)

        let card = ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(color.opacity(0.18))

                LucideIcon(name: icon, size: 56)
                    .foregroundStyle(color)
            }
            .frame(width: 100, height: 100)

            Circle()
                .fill(kind.color)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                .offset(x: 6, y: 6)
        }
        .frame(width: 112, height: 112, alignment: .topLeading)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            AppLog.error("іконку для банера намалювати не вдалося (\(icon)/\(item.color))")
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laserbeak-\(item.seq).png")

        do {
            try png.write(to: url)
            // Система забирає файл собі, тому з тимчасової теки він зникає.
            // Успіх окремо не пишемо: рядок «банер …» нижче вже каже, з якою іконкою.
            return try UNNotificationAttachment(identifier: "icon-\(item.seq)", url: url)
        } catch {
            AppLog.error("іконку в банер не додано: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Дані з черги

struct DaemonNotification: Codable, Identifiable {
    var seq: Int = 0
    var ts: Double = 0
    var kind: String = ""
    var sid: String = ""
    var session: String = ""
    var project: String = ""
    var color: String = ""
    var icon: String = ""
    var message: String = ""
    var sound: String = ""
    var appBundle: String = ""

    var id: Int { seq }

    init() {}

    enum CodingKeys: String, CodingKey {
        case seq, ts, kind, sid, session, project, color, icon, message, sound, appBundle
    }

    // Той самий підхід, що і в решті моделей: відсутнє поле не має
    // валити розбір усієї черги.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq        = (try? c.decodeIfPresent(Int.self, forKey: .seq)) ?? 0
        ts         = (try? c.decodeIfPresent(Double.self, forKey: .ts)) ?? 0
        kind       = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        sid        = (try? c.decodeIfPresent(String.self, forKey: .sid)) ?? ""
        session    = (try? c.decodeIfPresent(String.self, forKey: .session)) ?? ""
        project    = (try? c.decodeIfPresent(String.self, forKey: .project)) ?? ""
        color      = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? ""
        icon       = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? ""
        message    = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        sound      = (try? c.decodeIfPresent(String.self, forKey: .sound)) ?? ""
        appBundle  = (try? c.decodeIfPresent(String.self, forKey: .appBundle)) ?? ""
    }
}

struct NotificationBatch: Codable {
    var ok: Bool
    var seq: Int
    var notifications: [DaemonNotification]
}
