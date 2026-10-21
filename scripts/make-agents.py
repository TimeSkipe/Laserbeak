#!/usr/bin/env python3
"""Перетворює знаки агентів (Claude, Codex, Gemini) на код SwiftUI.

    python3 scripts/make-agents.py шлях/до/simple-icons/icons

Знаки беруться з Simple Icons (CC0) — однокольорові SVG у полі 24×24,
одна заливка. Геометрію розбирає той самий код, що й іконки Lucide
(scripts/make-lucide.py), а результат лягає в app/macOS/AgentIcons.swift.

Самі знаки — торгові марки своїх власників (Anthropic, OpenAI, Google).
У Laserbeak вони лише показують, який агент працює в сесії.

Взяти іконки, наприклад, так (версія та сама, що в шапці файлу):

    curl -O https://cdn.jsdelivr.net/npm/simple-icons@15.0.0/icons/claude.svg
"""

import importlib.util
import sys
from pathlib import Path as FSPath

ROOT = FSPath(__file__).resolve().parent.parent
OUT = ROOT / "app" / "macOS" / "AgentIcons.swift"
SIMPLE_ICONS = "15.0.0"

# Агент у Laserbeak → файл Simple Icons і колір знака на темному тлі.
# Колір Claude і Gemini — фірмовий з Simple Icons. Фірмовий OpenAI
# (#412991) на чорному острові не видно, тож Codex — без кольору: береться
# основний колір тексту, тобто білий у темній темі.
AGENTS = [
    ("claude", "claude", "D97757"),
    ("codex", "openai", None),
    ("gemini", "googlegemini", "8E75B2"),
]


def lucide_module():
    # Не лишати scripts/__pycache__ після кожного запуску.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("make_lucide", ROOT / "scripts" / "make-lucide.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def color_literal(hex_value):
    r, g, b = (int(hex_value[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"Color(red: {r:.3f}, green: {g:.3f}, blue: {b:.3f})"


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    source = FSPath(sys.argv[1])
    lucide = lucide_module()

    blocks, colors = [], []
    for agent, file, hex_value in AGENTS:
        svg = source / f"{file}.svg"
        if not svg.exists():
            print(f"  ⚠ пропускаю {agent}: немає {svg}")
            continue
        commands = lucide.convert(svg.read_text(encoding="utf-8"))
        blocks.append(f'    case "{agent}":\n' + "\n".join(lucide.swift_for(commands)))
        if hex_value:
            colors.append(f'        case "{agent}": return {color_literal(hex_value)}')
        print(f"  ✓ {agent} ← {file}.svg: {len(commands)} команд")

    names = ", ".join(f'"{a}"' for a, _, _ in AGENTS)
    swift = f'''import SwiftUI

// ЗГЕНЕРОВАНО scripts/make-agents.py — руками не правити.
//
// Знаки агентів із Simple Icons {SIMPLE_ICONS} (CC0): однокольорова заливка в
// полі 24×24. Самі знаки — торгові марки своїх власників (Anthropic, OpenAI,
// Google); тут вони лише показують, який агент працює в сесії.

enum AgentLogo {{
    /// Агенти, для яких є знак. Решта малюються запасним значком.
    static let names = [{names}]

    /// Колір знака на темному тлі; nil — основний колір тексту.
    static func color(_ agent: String) -> Color? {{
        switch agent {{
{chr(10).join(colors)}
        default: return nil
        }}
    }}

    /// Контур знака в системі координат 24×24; nil — знака немає.
    static func path(_ agent: String) -> Path? {{
        var p = Path()
        switch agent {{
{chr(10).join(blocks)}
        default:
            return nil
        }}
        return p
    }}
}}

struct AgentLogoShape: Shape {{
    let agent: String

    func path(in rect: CGRect) -> Path {{
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(
                translationX: rect.midX - 12 * scale,
                y: rect.midY - 12 * scale
            ))
        return (AgentLogo.path(agent) ?? Path()).applying(transform)
    }}
}}
'''

    OUT.write_text(swift, encoding="utf-8")
    print(f"✓ {OUT.relative_to(ROOT)} — {len(blocks)} знаків")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
