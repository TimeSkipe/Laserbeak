import SwiftUI
import Network

// Головний екран на телефоні.
//
// Усе, що видно, — це ті самі спільні екрани, що й на маку: проєкти,
// сесії, переписка з полем вводу, режим дозволів. Різниця в тому, як
// телефон дістається демона.
//
// Спершу треба один раз відсканувати код на маку: у ньому ключ доступу,
// без якого демон не віддає нічого. Ключ лягає в Keychain і більше не
// питається.
//
// Далі щоразу вибирається шлях:
//
//   1. прямий зашифрований канал до програми на маку — головний. Працює
//      навіть без спільної Wi-Fi, бо пристрої знаходять одне одного
//      через Bluetooth;
//   2. HTTP на демон за збереженою адресою — якщо програму на маку
//      закрито або прямий канал не склався.
//
// Перемикання відбувається саме собою: щойно прямий канал зʼявляється,
// переходимо на нього.

struct PhoneRootView: View {
    @ObservedObject var client: DaemonClient
    @ObservedObject var discovery: DiscoveryService

    @State private var pairing: Pairing?
    @State private var usingPeer = false
    @State private var showConnection = false
    @State private var showScanner = false

    @Environment(\.scenePhase) private var scenePhase

    /// Який саме шлях уже обрано. Потрібен, щоб не піднімати зʼєднання
    /// заново на кожну дрібну зміну в списку знайдених ноутів.
    @State private var route = ""

    /// Коли прямий канал востаннє підвів. Ноут може оголошувати сервіс,
    /// але не відповідати — програму приспали, кришку закрили. Тоді
    /// якийсь час навіть не пробуємо: інакше телефон застрягне, хоча
    /// поруч є робочий HTTP.
    ///
    /// Але відступати є куди далеко не завжди: за замовчуванням демон
    /// сидить лише на 127.0.0.1 і в мережі не оголошується взагалі.
    /// Тоді «запасний шлях» — це стара адреса з QR-коду, де ніхто не
    /// відповідає, і відступ означав би хвилину порожнього екрана
    /// замість одного перепідключення. Тому дивимось, чи справді є куди.
    @State private var peerFailedAt: Date?

    private static let peerCooldown: TimeInterval = 20

    private var isPaired: Bool { !(pairing?.token ?? "").isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionBar(client: client)
                Divider()

                if !isPaired {
                    NotPairedView { showScanner = true }
                } else if client.needsPairing {
                    KeyRejectedView { showScanner = true }
                } else if !client.isConnected && client.state == nil {
                    SearchingView(discovery: discovery)
                } else {
                    ProjectsView(client: client)
                }
            }
            .navigationTitle("Проєкти")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { await client.forceRefresh() }
            .sheet(isPresented: $showConnection) {
                ConnectionSheet(
                    client: client,
                    discovery: discovery,
                    pairing: pairing,
                    usingPeer: usingPeer,
                    onScan: { showConnection = false; showScanner = true },
                    onForget: {
                        PairingStore.forget()
                        pairing = nil
                        client.use(nil)
                        showConnection = false
                    }
                )
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { scanned in
                PairingStore.save(scanned)
                pairing = scanned

                // Ключ міг змінитись, а ноут лишитись тим самим — тоді
                // вибір шляху виглядає незмінним, хоч зʼєднання треба
                // піднімати наново. Тому забуваємо попередній вибір.
                route = ""
                peerFailedAt = nil
                connect()
            }
        }
        .task {
            pairing = PairingStore.load()
            connect()

            // Прямий канал міг бути недоступний, коли ми починали.
            // Періодично перепитуємо: connect() нічого не робить, якщо
            // вибір не змінився, тож це майже безкоштовно.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                connect()
            }
        }
        .onChange(of: discovery.macs) { _, _ in
            // Прямий канал міг щойно зʼявитись — або зникнути разом із
            // закритою програмою на маку.
            connect()
        }
        .onChange(of: client.isConnected) { _, connected in
            if connected {
                // Шлях працює: забуваємо, що колись не працював.
                if usingPeer { peerFailedAt = nil }
            } else if usingPeer, peerFailedAt == nil, hasHTTPFallback {
                // Прямий канал мовчить, і є куди відступити.
                peerFailedAt = Date()
                connect()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }

            // Повернулись у застосунок. Зʼєднання, яке лежало в кишені,
            // iOS уже прибрала, а пошук міг прокинутись мертвим. Тому не
            // чекаємо чергового такту: піднімаємо все одразу, інакше
            // перші секунди екран показує «немає звʼязку» на рівному
            // місці.
            discovery.ensureRunning()
            peerFailedAt = nil
            connect()
            Task { await client.refresh() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showConnection = true
            } label: {
                Image(systemName: connectionIcon)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await client.forceRefresh() }
            } label: {
                if client.isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(client.isRefreshing || !client.isConnected)
        }
    }

    /// Значок каже, яким шляхом ідуть дані просто зараз.
    private var connectionIcon: String {
        if !client.isConnected { return "desktopcomputer.trianglebadge.exclamationmark" }
        return usingPeer ? "lock.laptopcomputer" : "laptopcomputer"
    }

    // ------------------------------------------------------------ підключення

    /// Вибрати найкращий доступний шлях і віддати його клієнту.
    ///
    /// Викликається часто — на кожну зміну в мережі. Тому якщо вибір
    /// той самий, що й був, нічого не чіпаємо: підняти зʼєднання наново
    /// означало б скинути стан і блимнути порожнім екраном.
    private func connect() {
        guard let pairing, !pairing.token.isEmpty else {
            apply(route: "", usingPeer: false) { nil }
            return
        }

        if let mac = peerCandidate(for: pairing), let endpoint = mac.peer {
            apply(route: "peer:\(mac.name)", usingPeer: true) {
                PeerTransport(endpoint: endpoint, passcode: pairing.token, name: mac.name)
            }
            return
        }

        guard let url = freshestHTTPURL(for: pairing) else { return }

        apply(route: "http:\(url.absoluteString)", usingPeer: false) {
            HTTPTransport(baseURL: url, token: pairing.token)
        }
    }

    private func apply(route next: String, usingPeer peer: Bool, make: () -> DaemonTransport?) {
        guard next != route else { return }

        route = next
        usingPeer = peer
        client.use(make())
    }

    /// Ноут, з яким можна зʼєднатись напряму.
    ///
    /// Шукаємо за іменем, що приїхало з QR-коду. Якщо імені немає (код
    /// старого зразка) і поруч рівно один ноут — беремо його: помилитись
    /// нема з ким, а пароль однаково перевірить рукостискання.
    private func peerCandidate(for pairing: Pairing) -> DiscoveredMac? {
        if let failed = peerFailedAt, Date().timeIntervalSince(failed) < Self.peerCooldown {
            return nil
        }

        let withPeer = discovery.macs.filter(\.hasPeer)

        if !pairing.name.isEmpty {
            return withPeer.first { $0.name == pairing.name }
        }
        return withPeer.count == 1 ? withPeer.first : nil
    }

    /// Адреса для запасного шляху. Знайдена в мережі краща за збережену:
    /// IP ноута могли змінити, а імʼя лишається тим самим.
    private func freshestHTTPURL(for pairing: Pairing) -> URL? {
        liveHTTPURL(for: pairing) ?? pairing.baseURL
    }

    /// Адреса, яку демон оголошує просто зараз. Вона є лише тоді, коли
    /// запасний шлях справді ввімкнено ("bindHost": "0.0.0.0"): із
    /// замкненим демоном оголошувати нічого.
    private func liveHTTPURL(for pairing: Pairing) -> URL? {
        discovery.macs.first {
            $0.httpURL != nil && (pairing.name.isEmpty || $0.name == pairing.name)
        }?.httpURL
    }

    /// Чи є сенс кидати прямий канал. Якщо демон у мережі не
    /// оголошується, кидати нема на що: краще перепідключитись.
    private var hasHTTPFallback: Bool {
        guard let pairing else { return false }
        return liveHTTPURL(for: pairing) != nil
    }
}

// MARK: - Стани до підключення

struct NotPairedView: View {
    var onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Підключи ноут")
                .font(.headline)

            Text("На маку натисни значок QR у смужці стану Laserbeak "
                 + "і відскануй код. Це треба зробити один раз.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onScan) {
                Label("Сканувати код", systemImage: "camera")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct KeyRejectedView: View {
    var onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.slash")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Ключ більше не підходить")
                .font(.headline)

            Text("Схоже, на маку створили новий ключ. "
                 + "Відскануй код ще раз — це поверне доступ.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onScan) {
                Label("Сканувати код", systemImage: "camera")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SearchingView: View {
    @ObservedObject var discovery: DiscoveryService

    var body: some View {
        VStack(spacing: 12) {
            if discovery.isSearching {
                ProgressView()
                Text("Шукаю ноут…")
                    .font(.headline)
                Text("Прямий канал працює й без спільної Wi-Fi — "
                     + "аби програма Laserbeak була запущена на маку")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(discovery.lastError ?? "Пошук не запущено")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Підключення

/// Що зараз зі зʼєднанням і як його змінити.
struct ConnectionSheet: View {
    @ObservedObject var client: DaemonClient
    @ObservedObject var discovery: DiscoveryService

    let pairing: Pairing?
    let usingPeer: Bool
    var onScan: () -> Void
    var onForget: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(client.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)

                        Text(client.isConnected
                             ? (client.state?.host ?? "підключено")
                             : "немає зв'язку")

                        Spacer()

                        Text(client.target)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if client.isConnected {
                        Label(
                            usingPeer ? "Прямий зашифрований канал" : "HTTP у локальній мережі",
                            systemImage: usingPeer ? "lock.fill" : "wifi"
                        )
                        .font(.caption)
                        .foregroundStyle(usingPeer ? .green : .secondary)
                    }
                } header: {
                    Text("Зараз")
                } footer: {
                    Text(usingPeer
                         ? "Дані йдуть прямо між пристроями й зашифровані. Роутер не потрібен."
                         : "Прямий канал недоступний — схоже, програму на маку закрито. "
                           + "Працюємо по мережі, з ключем.")
                }

                Section {
                    if discovery.macs.isEmpty {
                        HStack(spacing: 8) {
                            if discovery.isSearching { ProgressView() }
                            Text(discovery.isSearching ? "Шукаю…" : "Нічого не знайдено")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(discovery.macs) { mac in
                            HStack {
                                Label(mac.name, systemImage: "desktopcomputer")

                                Spacer()

                                if mac.hasPeer {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                if let host = mac.host {
                                    Text(host)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Видно поруч")
                } footer: {
                    Text("Замок означає, що з цим ноутом можна зʼєднатись напряму.")
                }

                Section {
                    Button {
                        onScan()
                    } label: {
                        Label("Відсканувати код заново", systemImage: "qrcode.viewfinder")
                    }

                    if pairing != nil {
                        Button(role: .destructive, action: onForget) {
                            Label("Забути ноут", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Ключ доступу")
                } footer: {
                    Text(pairing.map { "Підключено до «\($0.name.isEmpty ? $0.host : $0.name)». "
                                       + "Ключ зберігається в Keychain телефона." }
                         ?? "Ноут ще не підключено.")
                }
            }
            .navigationTitle("Ноутбук")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
