import SwiftUI

// Екран підключення телефона.
//
// Показує QR-код, у якому лежить ключ доступу. Без цього ключа демон не
// віддає нічого — тож відсканувати код треба один раз, і це єдиний спосіб
// підключити телефон.
//
// Той самий ключ стає паролем прямого зашифрованого зʼєднання, тому
// секрет переноситься рівно раз: з екрана в камеру.

struct PairingView: View {
    @ObservedObject var client: DaemonClient
    @ObservedObject private var peer = PeerServer.shared

    @Environment(\.dismiss) private var dismiss

    @State private var chosen: String = ""
    @State private var token: String = ""
    @State private var showToken = false
    @State private var isRotating = false
    @State private var confirmRotate = false

    private var addresses: [DaemonAddress] {
        client.state?.addresses ?? []
    }

    private var port: Int { client.state?.port ?? 8787 }
    private var name: String { client.state?.host ?? "Laserbeak" }

    /// Чи відкритий запасний шлях по HTTP. Якщо ні — телефон працює
    /// виключно через цю програму, і це варто сказати вголос.
    private var hasFallback: Bool { client.state?.hasNetworkFallback ?? false }

    private var address: String {
        chosen.isEmpty ? (addresses.first?.address ?? "") : chosen
    }

    private var link: String {
        Connection.link(host: address, port: port, name: name, token: token)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if token.isEmpty {
                noToken
            } else {
                code
                Divider().padding(.vertical, 16)
                channel
            }

            Spacer(minLength: 16)

            footer
        }
        .padding(22)
        .frame(minWidth: 360)
        .task {
            token = await LocalDaemon.token()
            if chosen.isEmpty { chosen = addresses.first?.address ?? "" }
        }
        .confirmationDialog(
            String(localized: "Створити новий ключ?"),
            isPresented: $confirmRotate,
            titleVisibility: .visible
        ) {
            Button("Новий ключ", role: .destructive) { rotate() }
            Button("Скасувати", role: .cancel) { }
        } message: {
            Text("Усі підключені телефони втратять доступ, доки не відсканують код заново.")
        }
    }

    // ------------------------------------------------------------ шматки

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Підключити телефон")
                .font(.headline)
            Text("Відскануй код у Laserbeak на телефоні")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var code: some View {
        QRCodeView(text: link, size: 220)
            .padding(12)
            .background {
                // Світле тло під кодом: у темній темі його інакше
                // не зчитати.
                RoundedRectangle(cornerRadius: 10).fill(.white)
            }

        // Адреса потрібна лише запасному шляху по HTTP. Прямий канал
        // знаходить ноут за імʼям і в адресі не має потреби — тому коли
        // демон замкнено, показувати її було б брехнею.
        if hasFallback, !address.isEmpty {
            Text("\(address):\(port)")
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(.top, 12)
        } else if !hasFallback {
            Label("Демон замкнено на цьому компʼютері", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
        }

        if hasFallback, addresses.count > 1 {
            Picker("", selection: $chosen) {
                ForEach(addresses) { item in
                    Text("\(item.interfaceName) · \(item.address)")
                        .tag(item.address)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            .padding(.top, 8)
            .help("Адреса для запасного шляху, якщо прямий канал не складеться")
        }
    }

    /// Стан прямого каналу: без нього телефон працює лише по Wi-Fi.
    private var channel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: peer.isListening ? "lock.laptopcomputer" : "exclamationmark.triangle")
                    .foregroundStyle(peer.isListening ? .green : .orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.isListening ? String(localized: "Прямий канал увімкнено") : String(localized: "Прямий канал не працює"))
                        .font(.callout.weight(.medium))

                    Text(peer.isListening
                         ? (peer.peerCount > 0
                            ? "Підключено пристроїв: \(peer.peerCount)"
                            : String(localized: "Дані підуть зашифровано, повз роутер"))
                         : (peer.lastError ?? String(localized: "невідома причина")))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !hasFallback {
                        Text(String(localized: "Запасного шляху немає — телефон бачить сесії лише ")
                             + String(localized: "поки ця програма працює. Демон її підніме, якщо впаде."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 10) {
                Button(showToken ? String(localized: "Сховати ключ") : String(localized: "Показати ключ")) {
                    showToken.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button("Новий ключ") { confirmRotate = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(isRotating)
            }

            if showToken {
                Text(token)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noToken: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.slash")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)

            Text("Ключа немає")
                .font(.headline)

            Text("Демон не відповів. Перевір, чи він запущений: npm run logs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var footer: some View {
        HStack {
            Text("Ключ відкриває доступ до сесій — не показуй код чужим.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button("Закрити") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // ------------------------------------------------------------ дії

    private func rotate() {
        isRotating = true

        Task {
            let fresh = await LocalDaemon.rotateToken()
            if !fresh.isEmpty {
                token = fresh
                // Слухач має піднятись наново: пароль зʼєднання змінився.
                PeerServer.shared.start(
                    daemonURL: LocalDaemon.baseURL(),
                    passcode: fresh,
                    serviceName: LocalDaemon.serviceName()
                )
            }
            isRotating = false
        }
    }
}
