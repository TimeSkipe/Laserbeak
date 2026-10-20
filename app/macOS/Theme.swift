import SwiftUI
import AppKit

// Спільні шматки вигляду: картки, плашки статусів, плитки з іконками.
//
// Кольори — лише системні: вони самі підлаштовуються під світлу й темну
// теми й під акцентний колір, який людина вибрала в системі.

extension SessionStatus {
    var color: Color {
        switch self {
        case .idle:       return .secondary
        case .working:    return .blue
        case .waiting:    return .green
        case .needsInput: return .orange
        }
    }
}

extension ProjectStatus {
    var color: Color {
        switch self {
        case .needsInput: return .orange
        case .waiting:    return .green
        case .working:    return .blue
        case .idle:       return .secondary
        case .offline:    return .secondary
        }
    }
}

enum Theme {
    static let cardRadius: CGFloat = 12
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let windowFill = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
}

/// Підкладка картки: світліша за тло вікна, з тонкою рамкою й ледь
/// помітною тінню — щоб проєкти читались окремими блоками.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            }
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Кольорова плашка з крапкою: «працює», «чекає на дозвіл».
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// Плитка з іконкою Lucide у кольорі проєкту.
struct IconTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                LucideIcon(name: icon, size: size * 0.52)
                    .foregroundStyle(color)
            }
    }
}

/// Те саме для системних символів.
struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(color)
            }
    }
}

/// Значок стану сесії. Поки сесія працює, він пульсує — видно з першого
/// погляду, навіть не читаючи.
struct StatusBadge: View {
    let status: SessionStatus
    var size: CGFloat = 30

    var body: some View {
        Circle()
            .fill(status.color.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: status.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .working)
            }
    }
}

/// Маленька мітка поруч із назвою: «Codex».
struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Цифра з підписом у рамці — для деталей сесії.
struct StatTile: View {
    let title: String
    let value: String
    var accent: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
