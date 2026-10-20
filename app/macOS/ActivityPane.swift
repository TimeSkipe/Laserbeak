import SwiftUI

// Розділ «Активність»: що відбувалося із сесіями, від свіжого до
// старого. Історію веде демон — і тексти в ній уже його мовою.

struct ActivityPane: View {
    @ObservedObject var client: DaemonClient

    private var events: [ActivityEvent] { client.state?.history ?? [] }

    /// Події по днях: заголовок дня читається легше за дату в кожному рядку.
    private var days: [(day: Date, events: [ActivityEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { (day: $0.key, events: $0.value.sorted { $0.ts > $1.ts }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        Group {
            if events.isEmpty {
                VStack(spacing: 12) {
                    SymbolTile(symbol: "clock.arrow.circlepath", color: .purple, size: 64)
                    Text("Подій поки немає")
                        .font(.title3.weight(.semibold))
                    Text("Тут зʼявиться, коли сесії відкриваються, закінчують роботу чи чекають на дозвіл")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(days, id: \.day) { group in
                        Section {
                            ForEach(group.events) { event in
                                ActivityRow(event: event, title: title(for: event))
                            }
                        } header: {
                            Text(dayTitle(group.day))
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(SidebarItem.activity.title)
        .navigationSubtitle(String(localized: "останні події з усіх сесій"))
    }

    /// Назва сесії — та, що зараз: її могли перейменувати після події.
    private func title(for event: ActivityEvent) -> String {
        client.state?.sessions.first { $0.sid == event.sid }?.title ?? event.label
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Сьогодні") }
        if calendar.isDateInYesterday(day) { return String(localized: "Учора") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, color: color, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: title)
                        .font(.body.weight(.medium))
                    if !event.project.isEmpty {
                        Text(verbatim: event.project)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if !event.message.isEmpty {
                    Text(verbatim: event.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            Text(event.date, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch event.kind {
        case "stop":          return "checkmark"
        case "permission":    return "hand.raised.fill"
        case "idle":          return "hourglass"
        case "session-start": return "play.fill"
        case "session-end":   return "stop.fill"
        default:              return "circle.fill"
        }
    }

    private var color: Color {
        switch event.kind {
        case "stop":          return .green
        case "permission":    return .orange
        case "session-start": return .blue
        default:              return .gray
        }
    }
}
