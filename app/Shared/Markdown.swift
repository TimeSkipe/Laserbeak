import SwiftUI

// Показ маркдауну в переписці.
//
// НАВІЩО СВІЙ. SwiftUI вміє лише рядковий маркдаун — жирний, курсив,
// код, посилання. Заголовки, списки, таблиці й блоки коду він лишає як
// є, тому в чаті було видно сирі "## Вигляд" і "| а | б |".
//
// Бібліотеку не беремо з тієї ж причини, що й для іконок Lucide: одна
// залежність заради розмітки не варта того. Тим паче потрібен не весь
// маркдаун, а рівно те, що трапляється у відповідях.
//
// ЩО САМЕ ТРАПЛЯЄТЬСЯ. Порахував на 2402 реальних відповідях з архіву:
//
//   рядковий код `…`   56%      блок коду ```      7%
//   жирний **…**       47%      список 1.          4%
//   список -           12%      курсив *…*         3%
//   таблиця |          10%      лінія ---          1%
//   заголовок ##        9%      цитата >           1%
//
// Звідси й набір: усе з цього списку підтримано, решта лишається
// звичайним текстом. Таблиці й блоки коду прокручуються вбік — на
// телефоні вони інакше вилазять за екран.
//
// ПАСТКА ПРИ ПЕРЕВІРЦІ. ImageRenderer не малює вміст ScrollView: на
// картинці замість таблиці й коду порожні плитки. У самій програмі все
// на місці — я на цьому вже попався й ганявся за неіснуючою вадою.

// MARK: - Розбір

/// Один шматок розмітки. Рядкове оформлення всередині — окремо.
///
/// Навмисно НЕ Identifiable: блоки визначаються місцем у тексті, і
/// перелічувати їх треба за порядковим номером. Спершу тут був `id` із
/// `UUID()`, і це тихо ламало SwiftUI — при кожному розборі виходили
/// нові ідентифікатори, тобто список щоразу вважався іншим.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([Item])
    case numbers([Item])
    case code(language: String, text: String)
    case quote(String)
    case table(rows: [[String]])
    case rule

    /// Пункт списку разом із глибиною вкладеності.
    struct Item {
        var depth: Int
        var text: String
        var marker: String = ""   // "1." для нумерованих
    }
}

enum Markdown {
    /// Розібрати текст на блоки. Рядковий за рядком: цього досить для
    /// того маркдауну, який справді пишуть, і не тягне за собою станову
    /// машину на пів файлу.
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { index += 1; continue }

            // ``` — беремо все до закриття. Якщо закриття немає, до кінця:
            // відповідь могла обірватись посеред блоку.
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1

                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }   // саме закриття

                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            // Таблиця: рядок із трубами, під ним рядок-роздільник.
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                var rows: [[String]] = [tableCells(trimmed)]
                index += 2   // шапка та роздільник

                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(tableCells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }

                blocks.append(.table(rows: rows))
                continue
            }

            if bulletBody(trimmed) != nil {
                var items: [MarkdownBlock.Item] = []
                while index < lines.count {
                    let raw = lines[index]
                    guard let body = bulletBody(raw.trimmingCharacters(in: .whitespaces)) else { break }
                    items.append(.init(depth: depth(of: raw), text: body))
                    index += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            if let first = numberBody(trimmed) {
                var items: [MarkdownBlock.Item] = []
                var counter = first.number
                while index < lines.count {
                    let raw = lines[index]
                    guard let parsed = numberBody(raw.trimmingCharacters(in: .whitespaces)) else { break }
                    items.append(.init(depth: depth(of: raw), text: parsed.text, marker: "\(counter)."))
                    counter += 1
                    index += 1
                }
                blocks.append(.numbers(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var body: [String] = []
                while index < lines.count {
                    let raw = lines[index].trimmingCharacters(in: .whitespaces)
                    guard raw.hasPrefix(">") else { break }
                    body.append(String(raw.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(body.joined(separator: "\n")))
                continue
            }

            // Звичайний абзац: до порожнього рядка або до початку іншого
            // блоку. Переноси всередині абзацу зберігаємо — у відповідях
            // вони часто значущі.
            var body: [String] = []
            while index < lines.count {
                let raw = lines[index]
                let cut = raw.trimmingCharacters(in: .whitespaces)
                if cut.isEmpty || startsBlock(cut) { break }
                body.append(cut)
                index += 1
            }
            if !body.isEmpty { blocks.append(.paragraph(body.joined(separator: "\n"))) }
        }

        return blocks
    }

    // ------------------------------------------------------- дрібні розбори

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("|") || line.hasPrefix(">")
            || parseHeading(line) != nil || isRule(line)
            || bulletBody(line) != nil || numberBody(line) != nil
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var rest = Substring(line)

        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }

        guard level > 0, rest.first == " " else { return nil }
        return .heading(level: level, text: String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "-" } || line.allSatisfy { $0 == "*" }
            || line.allSatisfy { $0 == "_" }
    }

    /// "- текст" або "* текст" -> "текст"
    private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    /// "3. текст" -> (3, "текст")
    private static func numberBody(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }

        let rest = line.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }

        let body = rest.dropFirst()
        guard body.first == " " else { return nil }

        return (number, String(body).trimmingCharacters(in: .whitespaces))
    }

    /// Наскільки пункт списку зсунуто вправо. Два пробіли — один рівень.
    private static func depth(of line: String) -> Int {
        let spaces = line.prefix { $0 == " " }.count
        return min(spaces / 2, 3)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cut = line.trimmingCharacters(in: .whitespaces)
        guard cut.hasPrefix("|") else { return false }
        return cut.allSatisfy { "|-: ".contains($0) } && cut.contains("-")
    }

    private static func tableCells(_ line: String) -> [String] {
        var cut = Substring(line)
        if cut.hasPrefix("|") { cut = cut.dropFirst() }
        if cut.hasSuffix("|") { cut = cut.dropLast() }

        return cut.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // ------------------------------------------------------- рядкове оформлення

    /// Жирний, курсив, код і посилання всередині рядка.
    ///
    /// Тут уже допомагає сам SwiftUI: `AttributedString(markdown:)` це
    /// вміє. Але код він лише позначає намірами, не оформлює, — тож
    /// моноширинний шрифт і підкладку доводиться накладати самим.
    static func inline(_ source: String, font: Font = .callout) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        guard var text = try? AttributedString(markdown: source, options: options) else {
            // Розмітка зіпсована — краще показати як є, ніж нічого.
            return AttributedString(source)
        }

        // Спершу збираємо діапазони, і лише потім міняємо: правити рядок
        // під час обходу його ж пробігів не можна.
        let codeRanges = text.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { return nil }
            return run.range
        }

        // Код позначаємо підкладкою, а не кольором. Кольором було
        // крикливо: рядковий код трапляється в кожній другій відповіді,
        // і сторінка ставала строкатою.
        for range in codeRanges {
            text[range].font = .system(.callout, design: .monospaced)
            text[range].backgroundColor = .secondary.opacity(0.16)
        }

        return text
    }
}

// MARK: - Показ

/// Текст із розміткою: заголовки, списки, таблиці, код.
struct MarkdownText: View {
    let source: String
    var font: Font = .callout

    // Розбір коштує помітно менше за перемальовування, але робити його
    // на кожен такт оновлення (а чат оновлюється щодві секунди) все одно
    // ні до чого.
    private var blocks: [MarkdownBlock] { Markdown.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                // Заголовок мусить бути принаймні не дрібнішим за текст.
                // Спершу тут стояв .subheadline для другого рівня — а це
                // 15pt проти 16pt у .callout, тобто ієрархія працювала
                // навпаки, і "##" виглядав як звичайний жирний рядок.
                .font(level <= 1 ? .title3.weight(.semibold)
                     : level == 2 ? .headline
                                  : .callout.weight(.semibold))
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            Text(Markdown.inline(text, font: font))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: item.depth > 0 ? "◦" : "•", text: item.text, depth: item.depth)
                }
            }

        case .numbers(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: item.marker, text: item.text, depth: item.depth)
                }
            }

        case .code(let language, let text):
            codeBlock(language: language, text: text)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 2)
                Text(Markdown.inline(text, font: font))
                    .font(font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .table(let rows):
            tableView(rows)

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func listRow(marker: String, text: String, depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(font.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(Markdown.inline(text, font: font))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func codeBlock(language: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !language.isEmpty {
                Text(language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            // Код не переносимо: зламаний посередині рядок гірше, ніж
            // прокрутка. На телефоні це особливо помітно.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(9)
            }
            // Щоб смуга прокрутки брала висоту від коду, а не тягнулась
            // на все вільне місце по вертикалі.
            .fixedSize(horizontal: false, vertical: true)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary.opacity(0.6))
            }
        }
    }

    private func tableView(_ rows: [[String]]) -> some View {
        // Таблиці бувають ширші за екран телефона, тому вбік вони
        // прокручуються, а не стискаються до нечитабельного.
        ScrollView(.horizontal, showsIndicators: false) {
            // Зверху, а не посередині: висока комірка інакше підвішує
            // сусідні в порожнечі, і рядок читається гірше.
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            Text(Markdown.inline(cell))
                                .font(index == 0 ? .caption.weight(.semibold) : .caption)
                                .foregroundStyle(index == 0 ? .primary : .secondary)
                        }
                    }

                    if index == 0 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        // Та сама причина, що й у блоці коду: висота — від вмісту.
        .fixedSize(horizontal: false, vertical: true)
    }
}
