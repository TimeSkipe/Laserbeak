#!/usr/bin/env python3
"""Чи все перекладено всіма мовами — у програмі, розширенні, демоні й start.

    python3 scripts/check-l10n.py      # або: npm run check:l10n

Навіщо окремий скрипт. Збірка Xcode сама витягує в каталог лише рядки з
Text("…"), а з String(localized: "…") — ні: новий рядок тихо лишається
мовою оригіналу, і чеська програма раптом показує українську кнопку. У
розширенні гірше: chrome.i18n на відсутній ключ віддає порожній рядок,
тобто кнопку без напису. Тож перевіряємо все разом, з коду:

  програма     кожен рядок із коду є в Localizable.xcstrings усіма мовами,
               а плейсхолдери (%@, %d, %1$@…) у перекладах ті самі;
  розширення   кожна мова має ті самі ключі, що й uk, і ті самі $NAME$;
  демон        src/i18n.js — ті самі ключі й {плейсхолдери} у кожній мові;
  start/stop   shell/laserbeak.zsh — кожен ключ кожною мовою;
  скрипти      scripts/lang.sh — кожен ключ кожною мовою, ті самі %s, і
               кожен ключ, який просять install/uninstall/build/Node, є.

Мова оригіналу — українська: ключі каталогу — це українські рядки.
"""

import glob
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ["uk", "en", "cs", "ru", "kk"]

problems = []


def complain(where, text):
    problems.append(f"{where}: {text}")


# ------------------------------------------------------------ програма

CALLS = (r'(?:String\(localized:\s*|Text\(|Button\(|Label\(|Section\(|Toggle\(|Picker\('
         r'|LabeledContent\(|\.help\(|\.navigationTitle\(|\.navigationSubtitle\(|Menu\('
         r'|confirmationDialog\(\s*|Link\()')
LITERAL = r'"((?:[^"\\]|\\.)*)"'
CYRILLIC = re.compile(r'[А-Яа-яЄєІіЇїҐґʼ]')
SPECIFIER = re.compile(r'%(?:\d+\$)?(?:@|lld|d)')


def interpolation_to_format(s):
    """\\(вираз) у літералі SwiftUI стає %@ у ключі каталогу."""
    out, i = "", 0
    while i < len(s):
        if s.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(s) and depth:
                depth += {"(": 1, ")": -1}.get(s[j], 0)
                j += 1
            out += "%@"
            i = j
        else:
            out += s[i]
            i += 1
    return out


def swift_keys():
    keys = {}
    for path in sorted(glob.glob(str(ROOT / "app/macOS/*.swift"))):
        if path.endswith("LucideIcons.swift"):
            continue
        source = open(path, encoding="utf-8").read()
        for m in re.finditer(CALLS + LITERAL, source):
            key = interpolation_to_format(m.group(1)).replace('\\"', '"').replace("\\\\", "\\")
            if CYRILLIC.search(key) or key == "%@ — %@":
                keys.setdefault(key, Path(path).name)
    return keys


def specifiers(text):
    """Плейсхолдери без урахування порядку: %1$@ і %@ — те саме місце."""
    return sorted(re.sub(r"\d+\$", "", s) for s in SPECIFIER.findall(text))


def check_app():
    catalog = json.load(open(ROOT / "app/Resources/Localizable.xcstrings", encoding="utf-8"))["strings"]
    used = swift_keys()

    for key, where in used.items():
        entry = catalog.get(key)
        if not entry:
            complain("програма", f"немає в каталозі: {key!r} ({where})")
            continue
        for lang in LANGUAGES:
            unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
            if unit.get("state") != "translated" or not unit.get("value"):
                complain("програма", f"{lang}: не перекладено {key!r}")
            elif specifiers(unit["value"]) != specifiers(key):
                complain("програма", f"{lang}: плейсхолдери не ті в {key!r}")

    for key in catalog:
        if key not in used:
            complain("програма", f"у каталозі зайвий рядок, якого немає в коді: {key!r}")


# ------------------------------------------------------------ розширення

def check_extension():
    tables = {}
    for lang in LANGUAGES:
        path = ROOT / f"extension/_locales/{lang}/messages.json"
        if not path.exists():
            complain("розширення", f"немає _locales/{lang}/messages.json")
            continue
        tables[lang] = json.load(open(path, encoding="utf-8"))

    base = tables.get("uk", {})
    for lang, table in tables.items():
        if list(table) != list(base):
            missing = set(base) - set(table)
            extra = set(table) - set(base)
            complain("розширення", f"{lang}: ключі не збігаються з uk (бракує {sorted(missing)}, зайві {sorted(extra)})")
        for key, entry in table.items():
            if not entry.get("message"):
                complain("розширення", f"{lang}: порожнє {key}")
            want = sorted(re.findall(r"\$\w+\$", base.get(key, {}).get("message", "")))
            if sorted(re.findall(r"\$\w+\$", entry.get("message", ""))) != want:
                complain("розширення", f"{lang}: плейсхолдери не ті в {key}")

    # Ключі, які код просить у chrome.i18n. Неіснуючий — це порожня кнопка.
    used = set()
    for path in glob.glob(str(ROOT / "extension/*.js")):
        source = open(path, encoding="utf-8").read()
        used |= set(re.findall(r"\bmsg\(\s*'(\w+)'", source))
    for path in glob.glob(str(ROOT / "extension/*.html")):
        used |= set(re.findall(r'data-i18n="([^"]+)"', open(path, encoding="utf-8").read()))
    used |= set(re.findall(r"__MSG_(\w+)__", open(ROOT / "extension/manifest.json", encoding="utf-8").read()))
    for key in sorted(used - set(base)):
        complain("розширення", f"код просить ключ, якого немає: {key}")


# ------------------------------------------------------------ демон

def check_daemon():
    script = (
        "const src = require('fs').readFileSync(process.argv[1], 'utf8');"
        "const m = src.match(/const STRINGS = (\\{[\\s\\S]*?\\n\\});/);"
        "console.log(JSON.stringify(eval('(' + m[1] + ')')));"
    )
    strings = json.loads(subprocess.check_output(["node", "-e", script, str(ROOT / "src/i18n.js")]))

    base = strings.get("uk", {})
    for lang in LANGUAGES:
        table = strings.get(lang)
        if table is None:
            complain("демон", f"немає мови {lang} у src/i18n.js")
            continue
        for key in sorted(set(base) - set(table)):
            complain("демон", f"{lang}: бракує {key}")
        for key in sorted(set(table) - set(base)):
            complain("демон", f"{lang}: зайвий {key}")
        for key, text in table.items():
            if sorted(re.findall(r"\{\w+\}", text)) != sorted(re.findall(r"\{\w+\}", base.get(key, ""))):
                complain("демон", f"{lang}: плейсхолдери не ті в {key}")


# ------------------------------------------------------------ start / stop

def check_shell():
    source = open(ROOT / "shell/laserbeak.zsh", encoding="utf-8").read()
    seen = {}
    for m in re.finditer(r"^\s+((?:[a-z]{2}:[\w.]+\|?)+)\) text=", source, re.M):
        for pair in m.group(1).split("|"):
            lang, key = pair.split(":")
            seen.setdefault(key, set()).add(lang)
    for key, langs in sorted(seen.items()):
        for lang in LANGUAGES:
            if lang not in langs:
                complain("start/stop", f"{lang}: бракує {key}")


# ------------------------------------------------------------ скрипти установки

SCRIPT_ENTRY = re.compile(r"^\s+([a-z]{2}):([\w.]+)\) text=(['\"])(.*)\3 ;;$", re.M)


def check_scripts():
    """scripts/lang.sh — одна таблиця для install, uninstall, build і Node-скриптів."""
    table = {}
    for m in SCRIPT_ENTRY.finditer(open(ROOT / "scripts/lang.sh", encoding="utf-8").read()):
        table.setdefault(m.group(2), {})[m.group(1)] = m.group(4)

    for key, texts in sorted(table.items()):
        for lang in LANGUAGES:
            if lang not in texts:
                complain("скрипти", f"{lang}: бракує {key}")
        counts = {lang: text.count("%s") for lang, text in texts.items()}
        if len(set(counts.values())) > 1:
            complain("скрипти", f"різна кількість %s у {key}: {counts}")
        for lang, text in texts.items():
            # Текст іде в printf як формат і стоїть у лапках bash.
            if re.search(r"[$`\\]|%(?!s)", text):
                complain("скрипти", f"{lang}: у {key} є $, `, \\ або % не як %s")

    used = set()
    for path in glob.glob(str(ROOT / "scripts/*.sh")):
        used |= set(re.findall(r"\b(?:say|lb_t)\s+([a-z]+\.\w+)", open(path, encoding="utf-8").read()))
    for path in glob.glob(str(ROOT / "scripts/*.js")):
        used |= set(re.findall(r"\bt\(\s*'([a-z]+\.\w+)'", open(path, encoding="utf-8").read()))
    for key in sorted(used - set(table)):
        complain("скрипти", f"код просить ключ, якого немає: {key}")


check_app()
check_extension()
check_daemon()
check_shell()
check_scripts()

if problems:
    print("\n".join(problems))
    print(f"\n✖ проблем: {len(problems)}")
    sys.exit(1)

print(f"✓ усе перекладено: {', '.join(LANGUAGES)}")
