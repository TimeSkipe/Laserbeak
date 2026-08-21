import SwiftUI

// Дрібні відмінності розкладки між маком і телефоном.
//
// Спільні екрани — це добре, але сліпо спільні розміри — ні. Мінімальна
// ширина, розумна для вікна на маку, на телефоні виштовхує вміст за межі
// екрана: саме через це кнопка «надіслати» в чаті опинялась поза видимою
// частиною.

extension View {
    /// Мінімальні розміри застосовуються лише на маку.
    /// На телефоні вікно завжди на весь екран, і задавати ширину не можна.
    func windowSize(minWidth: CGFloat, minHeight: CGFloat? = nil) -> some View {
        modifier(WindowSize(minWidth: minWidth, minHeight: minHeight))
    }
}

private struct WindowSize: ViewModifier {
    let minWidth: CGFloat
    let minHeight: CGFloat?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        content
        #endif
    }
}

/// Чи це телефон. Потрібно там, де розкладка справді має відрізнятись,
/// а не просто масштабуватись.
enum Platform {
    static var isPhone: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}
