import Foundation
import Network

// Місток для телефона.
//
// Демон говорить лише HTTP і живе на 127.0.0.1. Телефон говорить
// зашифрованим p2p. Між ними стоїть ця штука: приймає зʼєднання, бере
// кадр із запитом, ходить на демон по loopback і віддає відповідь назад.
//
//   телефон ──TLS-PSK/AWDL──► програма на маку ──HTTP──► 127.0.0.1:8787
//
// Завдяки цьому демону вже не треба виглядати в мережу: у config.json
// можна поставити "bindHost": "127.0.0.1", і телефон працюватиме далі.
//
// Живе стільки, скільки живе програма — незалежно від того, чи відкрите
// вікно. Так само, як черга сповіщень.

@MainActor
final class PeerServer: ObservableObject {
    static let shared = PeerServer()

    @Published private(set) var isListening = false
    @Published private(set) var peerCount = 0
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "laserbeak.peer.server")

    /// Куди переказувати запити. Це завжди локальний демон.
    private var daemonURL: URL?

    /// Пароль зʼєднання — той самий ключ доступу, що й у QR-коді.
    private var passcode = ""

    private init() {}

    // ------------------------------------------------------------ запуск

    func start(daemonURL: URL?, passcode: String, serviceName: String) {
        // Ключ могли змінити кнопкою «Новий ключ» — тоді слухача треба
        // підняти наново, зі свіжим паролем.
        if isListening, passcode == self.passcode, daemonURL == self.daemonURL { return }

        // А от порожній ключ — це не зміна ключа, це «демон саме зараз
        // перезапускається». Раніше ми на цьому вбивали слухача й лишали
        // телефон без каналу до наступної перевірки, тобто на хвилину.
        // Тому: немає відповіді — нічого не чіпаємо, працюємо далі зі
        // старим паролем.
        guard !passcode.isEmpty else {
            if !isListening { lastError = "немає ключа доступу" }
            return
        }

        stop()

        self.daemonURL = daemonURL
        self.passcode = passcode

        do {
            let listener = try NWListener(using: PeerLink.parameters(passcode: passcode))

            // Ім'я сервісу — те саме, під яким ноут видно в мережі, щоб
            // на телефоні в списку був один зрозумілий рядок.
            listener.service = NWListener.Service(
                name: serviceName,
                type: PeerLink.serviceType
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handle(state: state) }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            AppLog.write("p2p: слухач не піднявся — \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil

        for connection in connections.values { connection.cancel() }
        connections.removeAll()

        isListening = false
        peerCount = 0
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            lastError = nil
            AppLog.write("p2p: чекаю на телефон (\(PeerLink.serviceType))")

        case .failed(let error):
            isListening = false
            lastError = error.localizedDescription
            AppLog.write("p2p: слухач впав — \(error.localizedDescription)")

            // Мережа могла просто зникнути (перемкнули Wi-Fi, закрили
            // кришку). Піднімаємось назад, а не мовчимо назавжди.
            let url = daemonURL
            let code = passcode
            let name = listener?.service?.name ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.start(daemonURL: url, passcode: code, serviceName: name)
            }

        case .cancelled:
            isListening = false

        default:
            break
        }
    }

    // ------------------------------------------------------------ обмін

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        peerCount = connections.count

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    AppLog.write("p2p: телефон підключився")
                case .failed(let error):
                    // Чужий пароль валиться саме тут, на рукостисканні.
                    AppLog.write("p2p: зʼєднання впало — \(NWConnection.explain(error))")
                    self?.drop(key)
                case .cancelled:
                    self?.drop(key)
                default:
                    break
                }
            }
        }

        connection.start(queue: queue)

        // Кожне зʼєднання обслуговується своїм циклом: телефон шле запити
        // по черзі, і відповідати треба в тому самому порядку.
        Task.detached { [weak self] in
            guard let self else { return }
            await self.serve(connection)
            await self.drop(key)
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        guard let connection = connections.removeValue(forKey: key) else { return }
        connection.cancel()
        peerCount = connections.count
    }

    private nonisolated func serve(_ connection: NWConnection) async {
        while true {
            do {
                let (request, body) = try await connection.receiveFrame(PeerRequest.self)
                let reply = await forward(request, body: body)

                try await connection.sendFrame(
                    header: PeerResponse(id: request.id, status: reply.status),
                    body: reply.data
                )
            } catch {
                // Телефон пішов або канал обірвався — це нормально.
                return
            }
        }
    }

    /// Переказати запит демону. Ключ доступу тут не потрібен: ми йдемо
    /// з 127.0.0.1, а такі запити демон пускає без нього.
    private nonisolated func forward(_ request: PeerRequest, body: Data) async -> DaemonReply {
        guard let base = await daemonURL else {
            return DaemonReply(status: 503, data: Self.error("демон не налаштовано"))
        }

        var components = URLComponents(
            url: base.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: false
        )
        if !request.query.isEmpty { components?.percentEncodedQuery = request.query }

        guard let url = components?.url else {
            return DaemonReply(status: 400, data: Self.error("поганий шлях"))
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = 30
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData

        if !body.isEmpty {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            return DaemonReply(status: status, data: data)
        } catch {
            return DaemonReply(status: 502, data: Self.error(error.localizedDescription))
        }
    }

    /// Помилку віддаємо в тому ж вигляді, що й демон, — клієнт не має
    /// розрізняти, хто саме відмовив.
    private nonisolated static func error(_ text: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": text])) ?? Data()
    }
}
