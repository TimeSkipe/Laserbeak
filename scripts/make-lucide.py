#!/usr/bin/env python3
"""Перетворює вибрані іконки Lucide на код SwiftUI.

    python3 scripts/make-lucide.py [шлях/до/lucide/icons]

SwiftUI не вміє SVG, а тягнути заради цього бібліотеку — зайве. Тому
геометрія іконок один раз перетворюється на команди SwiftUI Path і
лягає у згенерований файл app/Shared/LucideIcons.swift.

Іконки Lucide намальовані обведенням у полі 24×24 з товщиною лінії 2,
тому у Swift вони й малюються обведенням — колір і товщина задаються
на місці використання.

Дуги (команда A) переводяться в кубічні криві Безьє: SwiftUI не має
еліптичної дуги з такими ж параметрами, як у SVG.
"""

import math
import re
import sys
from pathlib import Path as FSPath
from xml.etree import ElementTree

ROOT = FSPath(__file__).resolve().parent.parent
OUT = ROOT / "app" / "Shared" / "LucideIcons.swift"

DEFAULT_SOURCE = FSPath.home() / "WebstormProjects/lucide/lucide-source/icons"

# Набір під проєкти: те, чим зазвичай хочеться їх позначити.
ICONS = [
    "folder", "code", "terminal", "rocket",
    "zap", "flame", "bug", "database",
    "globe", "layers", "package", "star",
    "server", "cpu", "palette", "wrench",
]

NUMBER = re.compile(r"[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?")
COMMAND = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])")


def numbers(text):
    return [float(n) for n in NUMBER.findall(text)]


def arc_to_beziers(x0, y0, rx, ry, angle, large_arc, sweep, x, y):
    """Еліптична дуга SVG -> послідовність кубічних кривих."""
    if rx == 0 or ry == 0 or (x0 == x and y0 == y):
        return [("L", x, y)]

    rx, ry = abs(rx), abs(ry)
    phi = math.radians(angle)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)

    dx2, dy2 = (x0 - x) / 2, (y0 - y) / 2
    x1 = cos_phi * dx2 + sin_phi * dy2
    y1 = -sin_phi * dx2 + cos_phi * dy2

    # Радіуси мусять бути достатніми, щоб дуга з'єднала кінці.
    lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lam > 1:
        scale = math.sqrt(lam)
        rx *= scale
        ry *= scale

    denom = (rx * rx * y1 * y1) + (ry * ry * x1 * x1)
    num = (rx * rx * ry * ry) - (rx * rx * y1 * y1) - (ry * ry * x1 * x1)
    factor = math.sqrt(max(0.0, num / denom)) if denom else 0.0
    if large_arc == sweep:
        factor = -factor

    cx1 = factor * rx * y1 / ry
    cy1 = -factor * ry * x1 / rx

    cx = cos_phi * cx1 - sin_phi * cy1 + (x0 + x) / 2
    cy = sin_phi * cx1 + cos_phi * cy1 + (y0 + y) / 2

    def angle_of(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        length = math.hypot(ux, uy) * math.hypot(vx, vy)
        if length == 0:
            return 0.0
        value = max(-1.0, min(1.0, dot / length))
        sign = -1.0 if (ux * vy - uy * vx) < 0 else 1.0
        return sign * math.acos(value)

    ux, uy = (x1 - cx1) / rx, (y1 - cy1) / ry
    vx, vy = (-x1 - cx1) / rx, (-y1 - cy1) / ry

    theta = angle_of(1, 0, ux, uy)
    delta = angle_of(ux, uy, vx, vy)

    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi

    # Одна крива Безьє точно описує щонайбільше чверть еліпса.
    segments = max(1, int(math.ceil(abs(delta) / (math.pi / 2))))
    step = delta / segments
    alpha = (4 / 3) * math.tan(step / 4)

    out = []
    for i in range(segments):
        a1 = theta + i * step
        a2 = a1 + step

        cos1, sin1 = math.cos(a1), math.sin(a1)
        cos2, sin2 = math.cos(a2), math.sin(a2)

        def point(c, s):
            return (
                cx + rx * c * cos_phi - ry * s * sin_phi,
                cy + rx * c * sin_phi + ry * s * cos_phi,
            )

        px1, py1 = point(cos1, sin1)
        px2, py2 = point(cos2, sin2)

        # Похідні у кінцях сегмента дають контрольні точки.
        d1x = -rx * sin1 * cos_phi - ry * cos1 * sin_phi
        d1y = -rx * sin1 * sin_phi + ry * cos1 * cos_phi
        d2x = -rx * sin2 * cos_phi - ry * cos2 * sin_phi
        d2y = -rx * sin2 * sin_phi + ry * cos2 * cos_phi

        out.append(("C",
                    px1 + alpha * d1x, py1 + alpha * d1y,
                    px2 - alpha * d2x, py2 - alpha * d2y,
                    px2, py2))

    return out


def parse_path(d):
    """d-атрибут -> список абсолютних команд M / L / C / Z."""
    tokens = [t for t in COMMAND.split(d) if t.strip()]
    out = []

    x = y = 0.0
    start_x = start_y = 0.0
    prev_cubic = None
    prev_quad = None
    command = None
    index = 0

    while index < len(tokens):
        token = tokens[index]

        if COMMAND.fullmatch(token):
            command = token
            index += 1
            args = numbers(tokens[index]) if index < len(tokens) and not COMMAND.fullmatch(tokens[index]) else []
            if args:
                index += 1
        else:
            args = numbers(token)
            index += 1

        upper = command.upper()
        relative = command.islower()
        cursor = 0

        # Кожна команда може нести кілька наборів аргументів підряд.
        while True:
            if upper == "Z":
                out.append(("Z",))
                x, y = start_x, start_y
                prev_cubic = prev_quad = None
                break

            need = {"M": 2, "L": 2, "H": 1, "V": 1,
                    "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7}[upper]
            if cursor + need > len(args):
                break

            chunk = args[cursor:cursor + need]
            cursor += need

            if upper == "M":
                nx, ny = chunk
                if relative:
                    nx, ny = x + nx, y + ny
                out.append(("M", nx, ny))
                x, y = nx, ny
                start_x, start_y = nx, ny
                # Наступні пари після M трактуються як L — так велить SVG.
                upper = "L"
                prev_cubic = prev_quad = None

            elif upper == "L":
                nx, ny = chunk
                if relative:
                    nx, ny = x + nx, y + ny
                out.append(("L", nx, ny))
                x, y = nx, ny
                prev_cubic = prev_quad = None

            elif upper == "H":
                nx = x + chunk[0] if relative else chunk[0]
                out.append(("L", nx, y))
                x = nx
                prev_cubic = prev_quad = None

            elif upper == "V":
                ny = y + chunk[0] if relative else chunk[0]
                out.append(("L", x, ny))
                y = ny
                prev_cubic = prev_quad = None

            elif upper == "C":
                c1x, c1y, c2x, c2y, nx, ny = chunk
                if relative:
                    c1x, c1y = x + c1x, y + c1y
                    c2x, c2y = x + c2x, y + c2y
                    nx, ny = x + nx, y + ny
                out.append(("C", c1x, c1y, c2x, c2y, nx, ny))
                prev_cubic = (c2x, c2y)
                prev_quad = None
                x, y = nx, ny

            elif upper == "S":
                c2x, c2y, nx, ny = chunk
                if relative:
                    c2x, c2y = x + c2x, y + c2y
                    nx, ny = x + nx, y + ny
                if prev_cubic:
                    c1x, c1y = 2 * x - prev_cubic[0], 2 * y - prev_cubic[1]
                else:
                    c1x, c1y = x, y
                out.append(("C", c1x, c1y, c2x, c2y, nx, ny))
                prev_cubic = (c2x, c2y)
                prev_quad = None
                x, y = nx, ny

            elif upper in ("Q", "T"):
                if upper == "Q":
                    qx, qy, nx, ny = chunk
                    if relative:
                        qx, qy = x + qx, y + qy
                        nx, ny = x + nx, y + ny
                else:
                    nx, ny = chunk
                    if relative:
                        nx, ny = x + nx, y + ny
                    if prev_quad:
                        qx, qy = 2 * x - prev_quad[0], 2 * y - prev_quad[1]
                    else:
                        qx, qy = x, y

                # Квадратична крива точно виражається через кубічну.
                c1x, c1y = x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y)
                c2x, c2y = nx + 2 / 3 * (qx - nx), ny + 2 / 3 * (qy - ny)
                out.append(("C", c1x, c1y, c2x, c2y, nx, ny))
                prev_quad = (qx, qy)
                prev_cubic = None
                x, y = nx, ny

            elif upper == "A":
                rx, ry, rot, large, sweep, nx, ny = chunk
                if relative:
                    nx, ny = x + nx, y + ny
                out.extend(arc_to_beziers(x, y, rx, ry, rot, int(large), int(sweep), nx, ny))
                x, y = nx, ny
                prev_cubic = prev_quad = None

            if cursor >= len(args):
                break

    return out


def circle_commands(cx, cy, rx, ry):
    """Коло чи еліпс — чотири дуги, зведені до кривих Безьє."""
    k = 0.5522847498307936
    return [
        ("M", cx, cy - ry),
        ("C", cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy),
        ("C", cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry),
        ("C", cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy),
        ("C", cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry),
        ("Z",),
    ]


def convert(svg_text):
    root = ElementTree.fromstring(svg_text)
    commands = []

    for element in root.iter():
        tag = element.tag.split("}")[-1]
        get = lambda name, default=0.0: float(element.get(name, default))

        if tag == "path":
            commands += parse_path(element.get("d", ""))

        elif tag == "circle":
            commands += circle_commands(get("cx"), get("cy"), get("r"), get("r"))

        elif tag == "ellipse":
            commands += circle_commands(get("cx"), get("cy"), get("rx"), get("ry"))

        elif tag == "line":
            commands += [("M", get("x1"), get("y1")), ("L", get("x2"), get("y2"))]

        elif tag in ("polyline", "polygon"):
            points = numbers(element.get("points", ""))
            pairs = list(zip(points[0::2], points[1::2]))
            if pairs:
                commands.append(("M", *pairs[0]))
                commands += [("L", px, py) for px, py in pairs[1:]]
                if tag == "polygon":
                    commands.append(("Z",))

        elif tag == "rect":
            rx0, ry0 = get("x"), get("y")
            w, h = get("width"), get("height")
            commands += [("M", rx0, ry0), ("L", rx0 + w, ry0),
                         ("L", rx0 + w, ry0 + h), ("L", rx0, ry0 + h), ("Z",)]

    return commands


def swift_for(commands):
    def f(v):
        return f"{v:.3f}"

    lines = []
    for c in commands:
        if c[0] == "M":
            lines.append(f"        p.move(to: CGPoint(x: {f(c[1])}, y: {f(c[2])}))")
        elif c[0] == "L":
            lines.append(f"        p.addLine(to: CGPoint(x: {f(c[1])}, y: {f(c[2])}))")
        elif c[0] == "C":
            lines.append(
                f"        p.addCurve(to: CGPoint(x: {f(c[5])}, y: {f(c[6])}), "
                f"control1: CGPoint(x: {f(c[1])}, y: {f(c[2])}), "
                f"control2: CGPoint(x: {f(c[3])}, y: {f(c[4])}))"
            )
        elif c[0] == "Z":
            lines.append("        p.closeSubpath()")
    return lines


def main():
    source = FSPath(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SOURCE
    if not source.exists():
        print(f"немає теки з іконками: {source}", file=sys.stderr)
        return 1

    blocks = []
    for name in ICONS:
        svg = source / f"{name}.svg"
        if not svg.exists():
            print(f"  ⚠ пропускаю {name}: файлу немає")
            continue

        commands = convert(svg.read_text(encoding="utf-8"))
        body = "\n".join(swift_for(commands))
        blocks.append(f'    case "{name}":\n{body}')
        print(f"  ✓ {name}: {len(commands)} команд")

    swift = f'''import SwiftUI

// ЗГЕНЕРОВАНО scripts/make-lucide.py — руками не правити.
//
// Іконки Lucide (ISC), намальовані обведенням у полі 24×24 з товщиною
// лінії 2. SwiftUI не вміє SVG, тому геометрія один раз перетворена на
// команди Path; колір і розмір задаються на місці використання.

enum Lucide {{
    /// Усі доступні іконки, у порядку показу в списку вибору.
    static let names = [{", ".join(f'"{n}"' for n in ICONS)}]

    static let fallback = "folder"

    /// Контур іконки в системі координат 24×24.
    static func path(_ name: String) -> Path {{
        var p = Path()
        switch name {{
{chr(10).join(blocks)}
        default:
            return path(fallback)
        }}
        return p
    }}
}}

/// Іконка Lucide як в'юшка. Колір береться з foregroundStyle.
struct LucideIcon: View {{
    let name: String
    var size: CGFloat = 16

    var body: some View {{
        LucideShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: 2 * size / 24,
                                       lineCap: .round,
                                       lineJoin: .round))
            .frame(width: size, height: size)
    }}
}}

struct LucideShape: Shape {{
    let name: String

    func path(in rect: CGRect) -> Path {{
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(
                translationX: rect.midX - 12 * scale,
                y: rect.midY - 12 * scale
            ))
        return Lucide.path(name).applying(transform)
    }}
}}
'''

    OUT.write_text(swift, encoding="utf-8")
    print(f"✓ {OUT.relative_to(ROOT)} — {len(blocks)} іконок")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
