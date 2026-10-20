import Foundation

// Як програма розмовляє з демоном: звичайний HTTP на 127.0.0.1.
//
// Ключа немає: демон слухає лише цей компʼютер і пускає все, що прийшло
// звідси. Усе, що він уміє, описується одним методом — метод, шлях,
// параметри, тіло — і відповідь як є, сирими байтами. Розбирає їх уже
// той, хто питав.

/// Відповідь демона: код і тіло, ще не розібране.
struct DaemonReply {
    let status: Int
    let data: Data

    var isOK: Bool { status == 200 }

    /// Текст помилки, який демон уже переклав вибраною мовою.
    var errorText: String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["error"] as? String
    }
}

enum TransportError: LocalizedError {
    case badURL
    case broken(String)

    var errorDescription: String? {
        switch self {
        case .badURL:           return String(localized: "немає адреси демона")
        case .broken(let text): return text
        }
    }
}

struct DaemonHTTP: Sendable {
    let baseURL: URL

    func send(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval = 5
    ) async throws -> DaemonReply {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }

        guard let url = components?.url else { throw TransportError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.broken(String(localized: "незрозуміла відповідь"))
        }

        return DaemonReply(status: http.statusCode, data: data)
    }

    func get(_ path: String, timeout: TimeInterval = 5) async throws -> DaemonReply {
        try await send(method: "GET", path: path, timeout: timeout)
    }

    func post(_ path: String, json object: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> DaemonReply {
        let body = try? JSONSerialization.data(withJSONObject: object)
        return try await send(method: "POST", path: path, body: body, timeout: timeout)
    }
}
