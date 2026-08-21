import Foundation

// Як програма розмовляє з демоном.
//
// Шляхів два, і клієнт не має знати, який саме працює:
//
//   HTTPTransport   звичайний HTTP із ключем у заголовку. Так ходить
//                   програма на маку (на 127.0.0.1) і так лишається
//                   запасний шлях для телефона у своїй Wi-Fi.
//
//   PeerTransport   зашифроване зʼєднання прямо між пристроями, без
//                   роутера. Так телефон говорить із маком за
//                   замовчуванням — див. PeerLink.swift.
//
// Тому все, що вміє демон, описується одним методом: метод, шлях,
// параметри, тіло — і відповідь як є, сирими байтами. Розбирає їх уже
// той, хто питав.

/// Відповідь демона: код і тіло, ще не розібране.
struct DaemonReply {
    let status: Int
    let data: Data

    var isOK: Bool { status == 200 }

    /// Ключ не підійшов — телефон треба підключити наново.
    var isUnauthorized: Bool { status == 401 }
}

enum TransportError: LocalizedError {
    case notConnected
    case unauthorized
    case tooLarge(Int)
    case broken(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConnected:     return "немає зʼєднання"
        case .unauthorized:     return "ключ доступу не підійшов"
        case .tooLarge(let n):  return "завелика відповідь (\(n) байтів)"
        case .broken(let text): return text
        case .timedOut:         return "демон не відповів"
        }
    }
}

protocol DaemonTransport: AnyObject, Sendable {
    /// Чи готовий транспорт нести запити просто зараз.
    var isReady: Bool { get }

    /// Як показати це зʼєднання користувачу: «192.168.1.137» або «поруч».
    var describeTarget: String { get }

    func send(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> DaemonReply
}

extension DaemonTransport {
    func get(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 5) async throws -> DaemonReply {
        try await send(method: "GET", path: path, query: query, body: nil, timeout: timeout)
    }

    func post(_ path: String, json object: [String: Any], timeout: TimeInterval = 15) async throws -> DaemonReply {
        let body = try? JSONSerialization.data(withJSONObject: object)
        return try await send(method: "POST", path: path, query: [], body: body, timeout: timeout)
    }
}

// MARK: - Звичайний HTTP

/// Ходить на демон по HTTP. Ключ доступу йде заголовком у кожному запиті:
/// без нього демон відповідає 401 усьому, що прийшло не з localhost.
final class HTTPTransport: DaemonTransport, @unchecked Sendable {
    let baseURL: URL
    private let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    var isReady: Bool { true }

    var describeTarget: String { baseURL.host ?? baseURL.absoluteString }

    func send(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> DaemonReply {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }

        guard let url = components?.url else { throw TransportError.notConnected }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Демон приймає і "Bearer x", і голий ключ; шлемо за правилами.
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.broken("незрозуміла відповідь")
        }

        return DaemonReply(status: http.statusCode, data: data)
    }
}
