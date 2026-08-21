#!/usr/bin/env python3
"""Робить іконки застосунку з однієї картинки.

    python3 scripts/make-icon.py <джерело.jpg>

Скрипт сам знаходить межі графіки й обрізає порожні поля навколо неї.
Це важливо: у більшості логотипів навколо знаку вже є повітря, і якщо
просто додати свої поля зверху, знак виходить помітно замалим.

macOS чекає на іконку з заокругленими кутами і полями по краях — інакше
вона виглядає чужою поруч із рештою програм у доці. iOS, навпаки, ріже
кути сама, тому там потрібен повний квадрат.
"""

import json
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "app" / "Resources" / "Assets.xcassets"

# Скільки місця займає плитка на полотні (решта — прозорі поля).
# Apple для macOS радить приблизно 80%.
MAC_TILE = 0.82
MAC_RADIUS = 0.225

# Скільки місця займає сам знак усередині плитки.
GLYPH_IN_TILE = 0.62

# На iOS кути ріже система, тому плитка — на все полотно.
IOS_GLYPH = 0.58

MAC_BASES = [16, 32, 128, 256, 512]
IOS_SIZE = 1024

# Пікселі, темніші за це, вважаються тлом.
BG_THRESHOLD = 24


def find_content(image: Image.Image):
    """Межі самої графіки без порожніх полів навколо."""
    gray = image.convert("L")
    mask = gray.point(lambda v: 255 if v > BG_THRESHOLD else 0)
    return mask.getbbox()


def background_color(image: Image.Image):
    """Колір тла беремо з кутів — так плитка зіллється з оригіналом."""
    w, h = image.size
    corners = [
        image.getpixel((0, 0)),
        image.getpixel((w - 1, 0)),
        image.getpixel((0, h - 1)),
        image.getpixel((w - 1, h - 1)),
    ]
    return tuple(sum(c[i] for c in corners) // 4 for i in range(3))


def extract_glyph(source: Image.Image) -> Image.Image:
    """Обрізати картинку рівно по графіці, вирівнявши її в квадрат."""
    bbox = find_content(source)
    if bbox is None:
        return source

    left, top, right, bottom = bbox
    side = max(right - left, bottom - top)
    cx, cy = (left + right) // 2, (top + bottom) // 2

    return source.crop((cx - side // 2, cy - side // 2,
                        cx + side // 2, cy + side // 2))


def rounded_mask(size: int, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), (size - 1, size - 1)],
                           radius=int(size * radius), fill=255)
    return mask


def compose(glyph: Image.Image, bg, size: int, glyph_ratio: float,
            rounded: bool, tile_ratio: float = 1.0) -> Image.Image:
    """Зібрати іконку: плитка тла + знак по центру."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    tile_size = max(1, int(size * tile_ratio))
    tile = Image.new("RGBA", (tile_size, tile_size), bg + (255,))

    glyph_size = max(1, int(tile_size * glyph_ratio))
    scaled = glyph.resize((glyph_size, glyph_size), Image.LANCZOS).convert("RGBA")

    offset = (tile_size - glyph_size) // 2
    tile.alpha_composite(scaled, (offset, offset))

    if rounded:
        tile.putalpha(rounded_mask(tile_size, MAC_RADIUS))

    inset = (size - tile_size) // 2
    canvas.paste(tile, (inset, inset), tile)
    return canvas


def main() -> int:
    if len(sys.argv) < 2:
        print("вкажи файл-джерело", file=sys.stderr)
        return 1

    src_path = Path(sys.argv[1]).expanduser()
    if not src_path.exists():
        print(f"немає файлу: {src_path}", file=sys.stderr)
        return 1

    source = Image.open(src_path).convert("RGB")
    bg = background_color(source)
    glyph = extract_glyph(source)

    print(f"  джерело {source.size[0]}×{source.size[1]} → "
          f"графіку обрізано до {glyph.size[0]}×{glyph.size[1]}, тло rgb{bg}")

    if ASSETS.exists():
        shutil.rmtree(ASSETS)

    mac_set = ASSETS / "AppIcon.appiconset"
    ios_set = ASSETS / "AppIconPhone.appiconset"
    mac_set.mkdir(parents=True)
    ios_set.mkdir(parents=True)

    (ASSETS / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2)
    )

    # ---------------------------------------------------------- macOS
    mac_images = []
    for base in MAC_BASES:
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            compose(glyph, bg, px, GLYPH_IN_TILE,
                    rounded=True, tile_ratio=MAC_TILE).save(mac_set / name)
            mac_images.append({
                "size": f"{base}x{base}",
                "idiom": "mac",
                "filename": name,
                "scale": f"{scale}x",
            })

    (mac_set / "Contents.json").write_text(json.dumps({
        "images": mac_images,
        "info": {"author": "xcode", "version": 1},
    }, indent=2))

    # ---------------------------------------------------------- iOS
    compose(glyph, bg, IOS_SIZE, IOS_GLYPH,
            rounded=False, tile_ratio=1.0).convert("RGB").save(ios_set / "icon_1024.png")

    (ios_set / "Contents.json").write_text(json.dumps({
        "images": [{
            "size": "1024x1024",
            "idiom": "universal",
            "filename": "icon_1024.png",
            "scale": "1x",
            "platform": "ios",
        }],
        "info": {"author": "xcode", "version": 1},
    }, indent=2))

    print(f"✓ іконки: {ASSETS.relative_to(ROOT)}")
    print(f"  macOS: {len(mac_images)} розмірів — плитка {MAC_TILE:.0%} полотна, "
          f"знак {GLYPH_IN_TILE:.0%} плитки")
    print(f"  iOS:   1024×1024 — знак {IOS_GLYPH:.0%} полотна, кути ріже система")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
