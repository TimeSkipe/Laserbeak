import Foundation
import Network

// Пошук ноута в мережі.
//
// Телефон не знає IP ноута і не має його знати: роутер сьогодні видав одну
// адресу, завтра іншу. Тому шукаємо за іменем.
//
// Шукаємо два різні сервіси, і це навмисно:
//
//   _laserbeak-p2p._tcp   зашифрований канал програми на маку. Головний
//                         шлях. Оголошується з includePeerToPeer, тому
//                         знаходиться навіть без спільної Wi-Fi — через
//                         Bluetooth, як AirDrop.
//
//   _laserbeak._tcp       сам демон. Потрібен лише запасному шляху по
//                         HTTP, і саме тому його доводиться резолвити
//                         в конкретні host:port.
//
// Обидва оголошуються під тим самим іменем (serviceName із конфігу), тож
// у списку вони зливаються в один ноут.

/// Знайдений ноут. Може мати один зі шляхів або обидва.
struct DiscoveredMac: Identifiable, Equatable {
    let name: String

    /// Кінцева точка прямого зашифрованого зʼєднання.
    var peer: NWEndpoint?

    /// Адреса демона для запасного шляху по HTTP.
    var host: String?
    var port: Int?

    var id: String { name }

    var hasPeer: Bool { peer != nil }

    var httpURL: URL? {
        guard let host, let port else { return nil }
        return URL(string: "http://\(host):\(port)")
    }
}

@MainActor
final class DiscoveryService: ObservableObject {
    static let peerService = PeerLink.serviceType
    static let httpService = "_laserbeak._tcp"

    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var isSearching = false
    @Published private(set) var lastError: String?

    private var peerBrowser: NWBrowser?
    private var httpBrowser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private var restartTask: Task<Void, Never>?

    /// Що бачить кожен із двох пошуків. Зводимо разом при кожній зміні.
    private var peerFound: [String: NWEndpoint] = [:]
    private var httpFound: [String: (host: String, port: Int)] = [:]

    func start() {
        guard peerBrowser == nil else { return }

        peerBrowser = browse(type: Self.peerService) { [weak self] results in
            self?.updatePeers(results)
        }

        httpBrowser = browse(type: Self.httpService) { [weak self] results in
            self?.updateHTTP(results)
        }
    }

    /// Переконатись, що пошук справді працює.
    ///
    /// Потрібно при поверненні в застосунок: телефон полежав у кишені,
    /// iOS приспала процес — і браузер прокидається мертвим. Доки його
    /// не піднімеш, ноут не зʼявиться в списку взагалі, тобто телефону
    /// нікуди підключатись.
    func ensureRunning() {
        if peerBrowser == nil {
            start()
        } else if !isSearching {
            restart()
        }
    }

    /// Підняти пошук наново. Знайдене не викидаємо: нехай список поки
    /// лишається таким, як був, — новий браузер його одразу перепише.
    func restart() {
        restartTask?.cancel()
        restartTask = nil

        peerBrowser?.cancel()
        httpBrowser?.cancel()
        peerBrowser = nil
        httpBrowser = nil

        start()
    }

    private func restartSoon() {
        guard restartTask == nil else { return }

        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.restartTask = nil
            self?.restart()
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil

        peerBrowser?.cancel()
        httpBrowser?.cancel()
        peerBrowser = nil
        httpBrowser = nil

        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()

        peerFound.removeAll()
        httpFound.removeAll()
        macs = []
        isSearching = false
    }

    private func browse(
        type: String,
        onResults: @escaping (Set<NWBrowser.Result>) -> Void
    ) -> NWBrowser {
        let parameters = NWParameters()

        // Без цього телефон не побачить ноут поза спільною Wi-Fi.
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isSearching = true
                    self?.lastError = nil
                case .failed(let error):
                    self?.isSearching = false
                    self?.lastError = error.localizedDescription

                    // Браузер сам не оживає. Мовчки лишитись без пошуку
                    // означає лишитись без ноута назовсім.
                    self?.restartSoon()
                case .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { results, _ in
            Task { @MainActor in onResults(results) }
        }

        browser.start(queue: .main)
        return browser
    }

    // ------------------------------------------------------------ прямий канал

    /// Тут резолвити нічого не треба: NWConnection приймає endpoint як є
    /// і сам доводить справу до кінця, зокрема через Bluetooth.
    private func updatePeers(_ results: Set<NWBrowser.Result>) {
        var found: [String: NWEndpoint] = [:]

        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            found[name] = result.endpoint
        }

        peerFound = found
        merge()
    }

    // ------------------------------------------------------------ запасний шлях

    /// А ось для HTTP потрібні саме host і port, тому кожен сервіс
    /// доводиться окремо резолвити через NWConnection: у currentPath
    /// лежить уже конкретна пара, з якої збирається URL.
    private func updateHTTP(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()

        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            seen.insert(name)

            if resolvers[name] == nil, httpFound[name] == nil {
                resolve(name: name, endpoint: result.endpoint)
            }
        }

        // Сервіс зник із мережі — прибираємо його адресу.
        for name in httpFound.keys where !seen.contains(name) {
            httpFound[name] = nil
        }
        for (name, connection) in resolvers where !seen.contains(name) {
            connection.cancel()
            resolvers[name] = nil
        }

        merge()
    }

    private func resolve(name: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else {
                if case .failed = state {
                    Task { @MainActor in self?.resolvers[name] = nil }
                    connection.cancel()
                }
                return
            }

            guard case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint else {
                connection.cancel()
                return
            }

            let text: String
            switch host {
            case .ipv4(let addr):
                text = "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
            case .ipv6(let addr):
                text = "[\((("\(addr)").components(separatedBy: "%").first ?? "\(addr)"))]"
            case .name(let value, _):
                text = value
            @unknown default:
                connection.cancel()
                return
            }

            Task { @MainActor in
                self?.httpFound[name] = (host: text, port: Int(port.rawValue))
                self?.resolvers[name] = nil
                self?.merge()
            }
            connection.cancel()
        }

        connection.start(queue: .main)
    }

    // ------------------------------------------------------------ зведення

    private func merge() {
        var byName: [String: DiscoveredMac] = [:]

        for (name, endpoint) in peerFound {
            byName[name] = DiscoveredMac(name: name, peer: endpoint)
        }

        for (name, address) in httpFound {
            var entry = byName[name] ?? DiscoveredMac(name: name)
            entry.host = address.host
            entry.port = address.port
            byName[name] = entry
        }

        // Ноути з прямим каналом — угорі: це головний шлях.
        macs = byName.values.sorted {
            $0.hasPeer != $1.hasPeer ? $0.hasPeer : $0.name < $1.name
        }
    }
}
