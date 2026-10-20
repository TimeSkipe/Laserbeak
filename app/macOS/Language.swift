import Foundation
import AppKit

// Мова вікна програми.
//
// Мова в Laserbeak одна на все — банери, історія, це вікно, розширення
// браузера — і живе в ~/.laserbeak/config.json. Демон перечитує її на
// льоту. Вікно так не вміє: macOS вирішує, якою мовою малювати програму,
// ще до першого рядка нашого коду, читаючи AppleLanguages з її власних
// налаштувань. Тож мову ми кладемо туди, а діє вона з наступного запуску.
//
// Звідси два кроки:
//   • при кожному запуску переносимо мову з конфіга в AppleLanguages —
//     так правка конфіга руками теж доходить до вікна;
//   • коли мову міняють у налаштуваннях, кладемо її туди ж і пропонуємо
//     перезапустити програму.
//
// "auto" означає «як у системі». Демон тоді бере першу з мов системи, яку
// вміє (src/i18n.js), — і macOS для програми робить те саме. Розходяться
// вони лише тоді, коли жодної з наших мов у системі немає: демон тоді
// говорить англійською, а програма впала б на мову оригіналу, українську.
// Цей випадок закриваємо явно.

enum AppLanguage {
    static let supported = ["uk", "en", "cs", "ru", "kk"]

    /// Як мову показати у виборі: прапор і назва нею ж самою.
    static let names: [(code: String, flag: String, name: String)] = [
        ("uk", "🇺🇦", "Українська"),
        ("en", "🇬🇧", "English"),
        ("cs", "🇨🇿", "Čeština"),
        ("ru", "🇷🇺", "Русский"),
        ("kk", "🇰🇿", "Қазақша"),
    ]

    private static let key = "AppleLanguages"

    /// Якою мовою програма малює себе просто зараз. Вирішено при запуску
    /// й до перезапуску не зміниться.
    static let running: String = Bundle.main.preferredLocalizations.first ?? "uk"

    /// Перенести мову з конфіга в налаштування програми.
    static func applyFromConfig() {
        apply(configLanguage() ?? "auto")
    }

    static func apply(_ language: String) {
        let defaults = UserDefaults.standard

        if supported.contains(language) {
            defaults.set([language], forKey: key)
            return
        }

        // Своє прибираємо — і крізь нього видно мови системи.
        defaults.removeObject(forKey: key)
        let system = defaults.stringArray(forKey: key) ?? []
        if !system.contains(where: { supported.contains(String($0.prefix(2))) }) {
            defaults.set(["en"], forKey: key)
        }
    }

    /// Чи треба перезапуститись, щоб вікно заговорило мовою демона.
    static func needsRelaunch(daemonLanguage: String) -> Bool {
        !daemonLanguage.isEmpty && daemonLanguage != running
    }

    /// Перезапустити програму. Новий екземпляр чекає, доки цей справді
    /// завершиться: `open` на програму, що ще закривається, лише
    /// активував би її.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
            String(ProcessInfo.processInfo.processIdentifier),
        ]

        do {
            try task.run()
        } catch {
            AppLog.write("перезапуск не вдався: \(error.localizedDescription)")
            return
        }

        AppLog.write("перезапуск заради мови")
        NSApp.terminate(nil)
    }

    private static func configLanguage() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".laserbeak/config.json")

        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return object["language"] as? String
    }
}
