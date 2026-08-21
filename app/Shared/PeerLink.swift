import Foundation
import Network
import CryptoKit

// Пряме зашифроване зʼєднання між маком і телефоном.
//
// НАВІЩО. Демон — це Node, а тому вміє лише HTTP. Відкритий HTTP у Wi-Fi
// означає, що будь-хто в мережі читає твої проєкти й переписку. Ключ
// доступу це закриває, але трафік лишається відкритим, і телефон працює
// тільки в одній мережі з ноутом.
//
// Тут інакше: зʼєднання тримає програма на маку, а вона вже ходить на
// демон по 127.0.0.1. Тобто демон може взагалі не виглядати в мережу.
//
// ЯК ЦЕ ЗНАХОДИТЬ ОДНЕ ОДНОГО. includePeerToPeer вмикає те саме, чим
// користуються AirDrop і Handoff: пристрої бачать одне одного через
// Bluetooth, а дані йдуть по AWDL — прямому Wi-Fi між пристроями, без
// роутера. Тому спільна мережа не потрібна: працює навіть там, де Wi-Fi
// узагалі немає.
//
// Чистий Bluetooth (CoreBluetooth) для цього не годиться: пакет ~180
// байтів і кілька КБ/с. Знімок стану качається щодві секунди, і по BLE
// він би повз.
//
// ЧИМ ЗАХИЩЕНО. TLS із наперед відомим ключем (PSK): обидва боки
// виводять його з того самого пароля, який телефон один раз узяв із
// QR-коду. Чужий пароль валить саме рукостискання — перевірено, дає
// "bad MAC". Сертифікати не потрібні, довіряти нема кому: секрет ти
// переніс очима з екрана на камеру.

enum PeerLink {
    /// Той самий рядок має стояти в NSBonjourServices застосунку на телефоні,
    /// інакше iOS мовчки нічого не знайде.
    static let serviceType = "_laserbeak-p2p._tcp"

    /// Скільки байтів приймаємо одним кадром. Знімок стану — десятки
    /// кілобайтів, уся історія довгої сесії — одиниці мегабайтів.
    static let maxFrameBytes = 16 * 1024 * 1024

    /// Мітка, якою підсолюється пароль. Просто щоб ключ не збігався з
    /// іншим застосунком, який узяв би той самий пароль.
    private static let salt = "laserbeak"

    /// Параметри зʼєднання: TLS-PSK поверх TCP, з дозволом іти повз роутер.
    static func parameters(passcode: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()

        // Обрив помічається за десятки секунд, а не за хвилини: телефон
        // кладуть у кишеню, і зʼєднання зникає без жодного попередження.
        //
        // Спокуса поставити сюди 2/2/3 велика — обрив тоді видно за вісім
        // секунд. Але AWDL не лежить рівно: радіо ділиться з основною
        // Wi-Fi і засинає разом з екраном, тож пауза в кілька секунд —
        // це норма, а не смерть. З восьмисекундним вікном канал рвався
        // сам собою по кілька разів на годину. Обрив однаково помітить
        // таймаут запиту, тому тут потрібен запас, а не пильність.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3

        let parameters = NWParameters(tls: tlsOptions(passcode: passcode), tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Ключ TLS виводиться з пароля через HMAC, а не береться як є:
    /// PSK має бути рівно 32 байти, а пароль — це просто рядок.
    private static func tlsOptions(passcode: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        let key = SymmetricKey(data: Data(passcode.utf8))
        var code = HMAC<SHA256>.authenticationCode(for: Data(salt.utf8), using: key)

        let secret = withUnsafeBytes(of: &code) { DispatchData(bytes: $0) }
        let identity = Data(salt.utf8).withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            options.securityProtocolOptions,
            secret as __DispatchData,
            identity as __DispatchData
        )

        // TLS 1.3. Набір мусить бути заданий явно: без цього рядка
        // рукостискання з PSK не складається.
        sec_protocol_options_append_tls_ciphersuite(
            options.securityProtocolOptions,
            tls_ciphersuite_t.AES_128_GCM_SHA256
        )

        return options
    }
}

// MARK: - Кадри

// Один обмін — це два кадри в кожен бік: заголовок і тіло.
//
//   [4 байти: довжина заголовка][заголовок JSON][4 байти: довжина тіла][тіло]
//
// Тіло лишається сирими байтами й не загортається в JSON заголовка:
// інакше кожен знімок стану довелося б перекодовувати двічі на кожному
// боці — а він приходить щодві секунди.

/// Що телефон просить у мака.
struct PeerRequest: Codable {
    var id: Int
    var method: String
    var path: String
    var query: String     // вже зібраний рядок параметрів, без "?"
}

/// Що мак відповідає.
struct PeerResponse: Codable {
    var id: Int
    var status: Int
}

extension NWConnection {
    /// Надіслати кадр: заголовок і тіло одним записом, щоб вони не
    /// роз'їхались між пакетами.
    func sendFrame<Header: Encodable>(header: Header, body: Data) async throws {
        let headerData = try JSONEncoder().encode(header)

        var packet = Data()
        packet.append(bigEndian: UInt32(headerData.count))
        packet.append(headerData)
        packet.append(bigEndian: UInt32(body.count))
        packet.append(body)

        try await cancellable { (continuation: CheckedContinuation<Void, Error>) in
            self.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError.broken(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Прочитати кадр, надісланий sendFrame.
    func receiveFrame<Header: Decodable>(_ type: Header.Type) async throws -> (Header, Data) {
        let headerLength = try await receiveFrameLength()
        let headerData = try await receiveExactly(headerLength)
        let header = try JSONDecoder().decode(Header.self, from: headerData)

        let bodyLength = try await receiveFrameLength()
        let body = bodyLength == 0 ? Data() : try await receiveExactly(bodyLength)

        return (header, body)
    }

    /// Рівно `count` байтів. Network.framework сам добирає їх із мережі,
    /// коли minimum і maximum збігаються.
    fileprivate func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0, count <= PeerLink.maxFrameBytes else {
            throw TransportError.tooLarge(count)
        }

        return try await cancellable { (continuation: CheckedContinuation<Data, Error>) in
            self.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: TransportError.broken(error.localizedDescription))
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: TransportError.broken("зʼєднання закрито"))
                } else {
                    continuation.resume(throwing: TransportError.broken("кадр обірвано"))
                }
            }
        }
    }

    /// Продовження, яке помічає скасування задачі.
    ///
    /// Це не дрібниця. Зворотні виклики Network.framework не знають про
    /// скасування: якщо мак заснув, зʼєднання застрягає в підготовці, і
    /// продовження не розбудить ніхто. Група задач при цьому чекає на
    /// дочірню навіть після cancelAll() — тобто зовнішній таймаут не
    /// рятує, і запит висить вічно. Перевірено: телефон замерзав
    /// назавжди на чужому паролі.
    ///
    /// Тому на скасування рвемо саме зʼєднання: воно переходить у
    /// .cancelled, зворотний виклик спрацьовує, продовження звільняється.
    fileprivate func cancellable<T>(
        _ body: @escaping (CheckedContinuation<T, Error>) -> Void
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation(body)
        } onCancel: {
            self.cancel()
        }
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        var be = value.bigEndian
        append(Data(bytes: &be, count: 4))
    }

    func readBigEndian() -> Int {
        Int(withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
    }
}

extension NWConnection {
    fileprivate func receiveFrameLength() async throws -> Int {
        let raw = try await receiveExactly(4)
        let length = raw.readBigEndian()
        guard length <= PeerLink.maxFrameBytes else { throw TransportError.tooLarge(length) }
        return length
    }

    /// Дочекатись, доки зʼєднання справді підніметься (разом із TLS).
    ///
    /// stateUpdateHandler смикають не раз, а продовжити виконання можна
    /// рівно один — далі впаде весь процес. Тому одноразовий замок.
    func waitUntilReady(queue: DispatchQueue) async throws {
        let once = Readiness()

        try await cancellable { (continuation: CheckedContinuation<Void, Error>) in
            self.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !once.claim() { return }
                    continuation.resume()
                case .failed(let error):
                    if !once.claim() { return }
                    continuation.resume(throwing: TransportError.broken(Self.explain(error)))
                case .cancelled:
                    if !once.claim() { return }
                    continuation.resume(throwing: TransportError.notConnected)
                default:
                    break
                }
            }
            self.start(queue: queue)
        }
    }

    /// Помилки Network.framework незрозумілі самі по собі. Найважливішу
    /// перекладаємо: -9846 означає, що паролі не збіглись.
    static func explain(_ error: NWError) -> String {
        if case .tls(let status) = error, status == -9846 {
            return "пароль не підійшов — відскануй код на маку заново"
        }
        return error.localizedDescription
    }
}

// MARK: - Транспорт на боці телефона
/// Зʼєднання телефона з маком.
///
/// Запити йдуть строго по черзі: канал один, а стрічка стану й переписка
/// оновлюються одночасно. Черга простіша за розкладання відповідей за
/// номерами й тут нічого не коштує — обмін іде за мілісекунди.
///
/// Черга мусить бути справжньою. Актор сам її не дає: на кожному await
/// він впускає наступний виклик, тож два запити починали слати кадри
/// одночасно й розбирали чужі відповіді. Тому нижче — явний замок.
final class PeerTransport: DaemonTransport, @unchecked Sendable {
    private let channel: PeerChannel
    private let readiness = Readiness()
    private let name: String

    init(endpoint: NWEndpoint, passcode: String, name: String) {
        self.name = name
        self.channel = PeerChannel(endpoint: endpoint, passcode: passcode, readiness: readiness)
    }

    var isReady: Bool { readiness.value }

    var describeTarget: String { name.isEmpty ? "поруч" : name }

    func send(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> DaemonReply {
        var components = URLComponents()
        components.queryItems = query.isEmpty ? nil : query

        let request = PeerRequest(
            id: 0,
            method: method,
            path: path,
            query: components.percentEncodedQuery ?? ""
        )

        return try await channel.exchange(request, body: body ?? Data(), timeout: timeout)
    }

    func disconnect() {
        Task { await channel.close() }
    }
}

/// Прапорець готовності, який видно ззовні актора.
final class Readiness: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Забрати право на одноразову дію. true дістанеться лише першому.
    func claim() -> Bool {
        lock.withLock {
            if stored { return false }
            stored = true
            return true
        }
    }
}

/// Сам канал: одне зʼєднання, через яке по черзі ходять усі запити.
private actor PeerChannel {
    private let endpoint: NWEndpoint
    private let passcode: String
    private let readiness: Readiness
    private let queue = DispatchQueue(label: "laserbeak.peer")

    /// Скільки чекаємо на саме рукостискання. Окремо від таймауту
    /// запиту: підняти канал по AWDL довше, ніж сходити по вже піднятому.
    private static let connectTimeout: TimeInterval = 8

    private var connection: NWConnection?
    private var counter = 0

    /// Замок: на дроті завжди рівно один запит.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(endpoint: NWEndpoint, passcode: String, readiness: Readiness) {
        self.endpoint = endpoint
        self.passcode = passcode
        self.readiness = readiness
    }

    // ------------------------------------------------------------ черга

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // ------------------------------------------------------------ зʼєднання

    /// Готове зʼєднання. Друге значення каже, чи воно вже було: на
    /// щойно піднятому повторювати запит немає сенсу.
    private func live() async throws -> (NWConnection, Bool) {
        if let connection, connection.state == .ready { return (connection, true) }

        connection?.cancel()
        connection = nil
        readiness.value = false

        let fresh = NWConnection(to: endpoint, using: PeerLink.parameters(passcode: passcode))

        // Рукостискання може не скластись мовчки: мак заснув або ключ
        // уже інший. Тоді продовження не розбудить ніхто — рятує лише
        // сторож, який рве саме зʼєднання (див. cancellable).
        let expired = Readiness()
        let connecting = Task { try await fresh.waitUntilReady(queue: queue) }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(Self.connectTimeout))
            _ = expired.claim()
            connecting.cancel()
        }
        defer { watchdog.cancel() }

        do {
            try await connecting.value
        } catch {
            fresh.cancel()
            throw expired.value
                ? TransportError.broken("мак не відповів — він заснув або ключ уже інший")
                : error
        }

        connection = fresh
        readiness.value = true
        return (fresh, false)
    }

    // ------------------------------------------------------------ обмін

    func exchange(_ request: PeerRequest, body: Data, timeout: TimeInterval) async throws -> DaemonReply {
        await acquire()
        defer { release() }

        // Нас могли скасувати, доки ми стояли в черзі: закрився екран
        // переписки. Канал тут ні до чого — виходимо, не чіпаючи його.
        try Task.checkCancellation()

        let (connection, reused) = try await live()

        do {
            return try await perform(on: connection, numbered(request), body: body, timeout: timeout)
        } catch {
            drop()

            // Зʼєднання, яке ми взяли вже готовим, могло померти ще до
            // запиту: телефон полежав у кишені, мак поспав. Це не обрив,
            // а застаріле зʼєднання — піднімаємо нове й пробуємо ще раз,
            // щоб на екрані нічого не блимнуло.
            //
            // Лише GET: POST міг долетіти до мака, і другий такий самий
            // написав би в сесію двічі.
            guard reused, request.method == "GET", !Task.isCancelled else { throw error }

            let (retry, _) = try await live()

            do {
                return try await perform(on: retry, numbered(request), body: body, timeout: timeout)
            } catch {
                drop()
                throw error
            }
        }
    }

    private func numbered(_ request: PeerRequest) -> PeerRequest {
        counter += 1
        var copy = request
        copy.id = counter
        return copy
    }

    /// Сам обмін.
    ///
    /// Виконує окрема задача, і це навмисно: коли той, хто питав, зникає
    /// (закрив екран переписки), кадр однаково має дочитатись до кінця —
    /// інакше наступний запит отримає хвіст чужої відповіді. Скасування
    /// ззовні тут більше не рве спільний канал.
    private func perform(
        on connection: NWConnection,
        _ request: PeerRequest,
        body: Data,
        timeout: TimeInterval
    ) async throws -> DaemonReply {
        let work = Task {
            try await connection.sendFrame(header: request, body: body)
            let (response, data): (PeerResponse, Data) = try await connection.receiveFrame(PeerResponse.self)
            return DaemonReply(status: response.status, data: data)
        }

        let expired = Readiness()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            _ = expired.claim()

            // Кадр уже посеред дороги, тож канал однаково зіпсовано:
            // рвемо зʼєднання, щоб продовження звільнилось.
            work.cancel()
        }
        defer { watchdog.cancel() }

        do {
            return try await work.value
        } catch {
            // Інакше нагору поїхало б голе CancellationError, і в смужці
            // стану стояло б слово, яке нічого не пояснює.
            throw expired.value ? TransportError.broken("мак не відповів вчасно") : error
        }
    }

    private func drop() {
        connection?.cancel()
        connection = nil
        readiness.value = false
    }

    func close() {
        drop()
    }
}
