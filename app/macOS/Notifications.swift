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
enum AppLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".laserbeak/app.log")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
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

    private func requestAuthorization() {
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            AppLog.write("статус сповіщень: \(settings.authorizationStatus.rawValue)")

            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    AppLog.write("запит дозволу не вдався: \(error.localizedDescription)")
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

    /// Клік по банеру відкриває редактор, з якого сесію запущено.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
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
            } catch {
                // Демон лежить або запит обірвався — почекаємо і спробуємо знову.
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func show(_ item: DaemonNotification) {
        let content = UNMutableNotificationContent()
        content.title = item.session
        if !item.project.isEmpty { content.subtitle = item.project }
        content.body = item.message
        content.userInfo = ["appBundle": item.appBundle, "sid": item.sid]

        if !item.sound.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(item.sound + ".aiff"))
        }

        // Сповіщення однієї сесії групуються разом.
        content.threadIdentifier = item.sid

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
                AppLog.write("банер не показано: \(error.localizedDescription)")
                Task { @MainActor in self?.lastError = error.localizedDescription }
            } else {
                AppLog.write("банер показано: \(item.session) · \(item.project)")
            }
        }
    }
}

// MARK: - Картинка для банера

extension NotificationService {
    /// Малює іконку проєкту в його кольорі й віддає як вкладення банера.
    ///
    /// UNNotificationAttachment приймає лише файл, тому картинка щоразу
    /// пишеться в тимчасову теку. Файли дрібні, система прибирає їх сама.
    func iconAttachment(for item: DaemonNotification) -> UNNotificationAttachment? {
        let color = Palette.color(item.color) ?? .secondary
        let icon = item.icon.isEmpty ? Lucide.fallback : item.icon

        let card = ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(color.opacity(0.18))

            LucideIcon(name: icon, size: 60)
                .foregroundStyle(color)
        }
        .frame(width: 100, height: 100)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            AppLog.write("іконку намалювати не вдалося (\(icon)/\(item.color))")
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laserbeak-\(item.seq).png")

        do {
            try png.write(to: url)
            // Система забирає файл собі, тому з тимчасової теки він зникає.
            let attachment = try UNNotificationAttachment(identifier: "icon-\(item.seq)", url: url)
            AppLog.write("іконка в банері: \(icon), колір \(item.color.isEmpty ? "типовий" : item.color)")
            return attachment
        } catch {
            AppLog.write("іконку в банер не додано: \(error.localizedDescription)")
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
