import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// QR-код для підключення телефона.
//
// Код несе ключ доступу — і це головне, що він робить. Демон без ключа
// не віддає нічого, тож зчитати код означає отримати право читати стан
// і писати в сесії. Той самий ключ стає паролем зашифрованого зʼєднання
// (див. PeerLink.swift), тому секрет переноситься рівно один раз: очима
// з екрана мака в камеру телефона.
//
// Адреса й порт лишаються в коді як запасний шлях: якщо пряме зʼєднання
// не складеться, телефон піде на демон по HTTP у своїй Wi-Fi.
//
// Формат навмисно простий і читабельний:
//   laserbeak://connect?host=192.168.1.137&port=8787&name=my-macbook&token=…

enum Connection {
    static let scheme = "laserbeak"

    /// Зібрати посилання для QR-коду.
    static func link(host: String, port: Int, name: String, token: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "token", value: token),
        ]
        return components.string ?? ""
    }

    /// Розібрати зчитане з QR. Приймає і повне посилання, і просто
    /// "192.168.1.137:8787" — на випадок ручного вводу. У другому разі
    /// ключа немає, і демон відмовить: код доведеться таки відсканувати.
    static func parse(_ text: String) -> Pairing? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("\(scheme)://"),
           let components = URLComponents(string: trimmed) {
            let items = components.queryItems ?? []
            let host = items.first { $0.name == "host" }?.value ?? ""
            let port = Int(items.first { $0.name == "port" }?.value ?? "") ?? 8787
            let name = items.first { $0.name == "name" }?.value ?? ""
            let token = items.first { $0.name == "token" }?.value ?? ""

            guard !host.isEmpty else { return nil }
            return Pairing(name: name, host: host, port: port, token: token)
        }

        // Проста форма: host або host:port
        let plain = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let parts = plain.split(separator: ":", maxSplits: 1)
        guard let host = parts.first, !host.isEmpty else { return nil }

        let port = parts.count > 1 ? (Int(parts[1]) ?? 8787) : 8787
        return Pairing(name: "", host: String(host), port: port, token: "")
    }
}

/// Малює QR-код із тексту.
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 220

    var body: some View {
        if let image = Self.make(text, size: size) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)          // без згладжування, інакше код розмиває
                .resizable()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: size, height: size)
                .overlay { Text("не вдалося").font(.caption).foregroundStyle(.secondary) }
        }
    }

    static func make(_ text: String, size: CGFloat) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        // Збільшуємо до потрібного розміру цілим множником, щоб модулі
        // лишались рівними квадратами.
        let scale = max(1, size / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
