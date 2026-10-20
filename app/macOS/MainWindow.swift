import SwiftUI
import AppKit

// Головне вікно: бічна панель зліва, вибраний розділ справа.

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case sessions, activity, general, notifications, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions:      return String(localized: "Сесії")
        case .activity:      return String(localized: "Активність")
        case .general:       return String(localized: "Загальні")
        case .notifications: return String(localized: "Сповіщення")
        case .updates:       return String(localized: "Оновлення")
        }
    }

    var symbol: String {
        switch self {
        case .sessions:      return "square.stack.3d.up.fill"
        case .activity:      return "clock.arrow.circlepath"
        case .general:       return "gearshape.fill"
        case .notifications: return "bell.badge.fill"
        case .updates:       return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .sessions:      return .blue
        case .activity:      return .purple
        case .general:       return .gray
        case .notifications: return .red
        case .updates:       return .green
        }
    }
}

struct MainWindow: View {
    @ObservedObject var client: DaemonClient
    @ObservedObject var router: AppRouter

    var body: some View {
        NavigationSplitView {
            Sidebar(client: client, selection: $router.section)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowFill)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.section {
        case .sessions:      SessionsPane(client: client)
        case .activity:      ActivityPane(client: client)
        case .general:       GeneralPane(client: client)
        case .notifications: NotificationsPane(client: client)
        case .updates:       UpdatesPane(client: client)
        }
    }
}

// MARK: - Бічна панель

struct Sidebar: View {
    @ObservedObject var client: DaemonClient
    @Binding var selection: SidebarItem

    private var update: UpdateSummary { client.state?.update ?? UpdateSummary() }

    var body: some View {
        List(selection: $selection) {
            // Мітка (.tag) — завжди останньою, після .badge: інакше рядок
            // із лічильником перестає вибиратись, і з «Активності» вже не
            // повернутись на «Сесії».
            Section {
                row(.sessions)
                    .badge(client.state?.sessions.count ?? 0)
                    .tag(SidebarItem.sessions)
                row(.activity)
                    .tag(SidebarItem.activity)
            } header: {
                Brand(client: client)
            }

            Section("Налаштування") {
                row(.general)
                    .tag(SidebarItem.general)
                row(.notifications)
                    .tag(SidebarItem.notifications)
                row(.updates)
                    .badge(update.isAvailable ? Text(verbatim: update.behindText) : nil)
                    .tag(SidebarItem.updates)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if update.isAvailable || update.isInstalling {
                    UpdateNudge(update: update) { selection = .updates }
                }
                if AppLanguage.needsRelaunch(daemonLanguage: client.state?.language ?? "") {
                    LanguageNudge()
                }
            }
            .padding(12)
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.symbol)
                .foregroundStyle(item.tint)
        }
    }
}

/// Шапка бічної панелі: іконка, назва і чи живий демон.
private struct Brand: View {
    @ObservedObject var client: DaemonClient

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Laserbeak")
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(client.isConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(client.isConnected
                         ? (client.state?.host ?? String(localized: "підключено"))
                         : String(localized: "демон не відповідає"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }
}

/// Плашка «є оновлення» внизу бічної панелі.
private struct UpdateNudge: View {
    let update: UpdateSummary
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                if update.isInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.white, .green)
                        .font(.title3)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(update.isInstalling ? String(localized: "Оновлюю…") : String(localized: "Доступне оновлення"))
                        .font(.callout.weight(.semibold))
                    if !update.isInstalling {
                        Text(String(format: String(localized: "Нових змін: %@"), update.behindText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Мову змінили, поки програма працювала: демон уже говорить новою,
/// вікно — ще старою.
private struct LanguageNudge: View {
    // Дві стрічки, а не одна: назва кнопки в деяких мовах удвічі довша
    // за українську й на одній стрічці з текстом обрізалась би.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Мову змінено", systemImage: "globe")
                .font(.callout.weight(.medium))
            Button("Перезапустити") { AppLanguage.relaunch() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
