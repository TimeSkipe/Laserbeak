import SwiftUI

// Палітра кольорів проєктів.
//
// Зберігається назва, а не код кольору: системні кольори самі
// підлаштовуються під світлу й темну теми, а назва лишається читабельною
// у projects.json і однаково працює на маку й на телефоні.

enum Palette {
    static let names = [
        "blue", "purple", "pink", "red",
        "orange", "yellow", "green", "teal",
    ]

    static let titles: [String: String] = [
        "blue": "синій",
        "purple": "фіолетовий",
        "pink": "рожевий",
        "red": "червоний",
        "orange": "помаранчевий",
        "yellow": "жовтий",
        "green": "зелений",
        "teal": "бірюзовий",
    ]

    static func color(_ name: String) -> Color? {
        switch name {
        case "blue":   return .blue
        case "purple": return .purple
        case "pink":   return .pink
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "teal":   return .teal
        default:       return nil
        }
    }
}

extension Project {
    /// Колір проєкту: обраний користувачем, інакше — за станом сесій.
    var accent: Color {
        Palette.color(settings.color) ?? state.color
    }

    var hasCustomColor: Bool {
        Palette.color(settings.color) != nil
    }
}
