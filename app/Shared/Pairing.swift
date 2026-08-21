import Foundation
import Security

// Памʼять телефона про підключений ноут.
//
// Ключ доступу — це секрет: він відкриває і читання стану, і запис у
// сесії. Тому він лежить у Keychain, а не в UserDefaults: у Keychain
// його не видно в бекапі відкритим текстом і не витягти з файлів
// застосунку.
//
// Адреса ноута секретом не є, тож лишається у звичайних налаштуваннях.

struct Pairing: Equatable {
    var name: String        // як ноут зветься в мережі
    var host: String
    var port: Int
    var token: String

    var baseURL: URL? { URL(string: "http://\(host):\(port)") }

    var hostPort: String { "\(host):\(port)" }
}

enum PairingStore {
    private static let service = "com.laserbeak.pairing"
    private static let account = "daemon-token"

    private static let hostKey = "pairedHost"
    private static let portKey = "pairedPort"
    private static let nameKey = "pairedName"

    /// Що зберегли минулого разу. Порожній ключ означає, що телефон ще
    /// не підключали — тоді потрібен QR-код із мака.
    static func load() -> Pairing? {
        let defaults = UserDefaults.standard

        let host = defaults.string(forKey: hostKey) ?? ""
        let port = defaults.integer(forKey: portKey)
        guard !host.isEmpty, port > 0 else { return nil }

        return Pairing(
            name: defaults.string(forKey: nameKey) ?? "",
            host: host,
            port: port,
            token: readToken() ?? ""
        )
    }

    static func save(_ pairing: Pairing) {
        let defaults = UserDefaults.standard
        defaults.set(pairing.host, forKey: hostKey)
        defaults.set(pairing.port, forKey: portKey)
        defaults.set(pairing.name, forKey: nameKey)

        writeToken(pairing.token)
    }

    static func forget() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: portKey)
        defaults.removeObject(forKey: nameKey)

        SecItemDelete(query() as CFDictionary)
    }

    // ------------------------------------------------------------ Keychain

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readToken() -> String? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        return text
    }

    private static func writeToken(_ token: String) {
        let data = Data(token.utf8)

        // Спершу пробуємо оновити наявний запис: SecItemAdd на вже
        // існуючому ключі поверне errSecDuplicateItem і нічого не зробить.
        let updated = SecItemUpdate(
            query() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return }

        var request = query()
        request[kSecValueData as String] = data

        // Ключ потрібен і тоді, коли телефон лежить у кишені заблокований,
        // — інакше застосунок не оновиться у фоні після перезавантаження.
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemAdd(request as CFDictionary, nil)
    }
}
