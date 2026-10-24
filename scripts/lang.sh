# Тексти скриптів установки п'ятьма мовами. Підключається через source:
#
#   . "$ROOT/scripts/lang.sh"
#   say install.check              # рядок і перенос
#   say install.daemonOk "$PORT"   # %s підставляє аргументи по черзі
#
# Ту саму таблицю читають і Node-скрипти (scripts/lang.js), тож переклад
# живе в одному місці, а npm run check:l10n перевіряє його разом з усім.
#
# Мова: LB_LANG (її передає install.sh дочірнім скриптам) → LASERBEAK_LANG
# → вибір у ~/.laserbeak/config.json → перша з мов системи
# (AppleLanguages), яку Laserbeak знає → en. Те саме правило, що для
# «auto» у демона й вікна.
#
# Правила для текстів: лише %s як місце для аргументу, без $, `, \ і
# апострофа ' (в українських словах — ʼ, U+02BC): текст стоїть в
# одинарних лапках і йде у printf як формат.

lb_system_lang() {
  local code
  for code in $(defaults read -g AppleLanguages 2>/dev/null | tr -d ' ",()' | sed -E 's/[-_].*//'); do
    case "$code" in uk|en|cs|ru|kk) echo "$code"; return ;; esac
  done
  echo en
}

lb_detect_lang() {
  local want="${LASERBEAK_LANG:-}"
  case "$want" in uk|en|cs|ru|kk) echo "$want"; return ;; esac

  local config="$HOME/.laserbeak/config.json"
  if [ -f "$config" ]; then
    want="$(sed -nE 's/.*"language"[[:space:]]*:[[:space:]]*"([a-z]+)".*/\1/p' "$config" | head -1)"
    case "$want" in uk|en|cs|ru|kk) echo "$want"; return ;; esac
  fi

  lb_system_lang
}

LB_LANG="${LB_LANG:-$(lb_detect_lang)}"

lb_t() {
  local key="$1"; shift
  local text=''
  case "$LB_LANG:$key" in
    uk:install.code) text='код' ;;
    en:install.code) text='code' ;;
    cs:install.code) text='kód' ;;
    ru:install.code) text='код' ;;
    kk:install.code) text='код' ;;

    uk:install.data) text='дані' ;;
    en:install.data) text='data' ;;
    cs:install.data) text='data' ;;
    ru:install.data) text='данные' ;;
    kk:install.data) text='деректер' ;;

    uk:install.langUnknown) text='  ⚠ мова «%s» невідома — беру auto' ;;
    en:install.langUnknown) text='  ⚠ unknown language "%s" — using auto' ;;
    cs:install.langUnknown) text='  ⚠ jazyk „%s“ neznám — beru auto' ;;
    ru:install.langUnknown) text='  ⚠ язык «%s» неизвестен — беру auto' ;;
    kk:install.langUnknown) text='  ⚠ «%s» тілі белгісіз — auto таңдаймын' ;;

    uk:install.lang) text='▸ мова: %s' ;;
    en:install.lang) text='▸ language: %s' ;;
    cs:install.lang) text='▸ jazyk: %s' ;;
    ru:install.lang) text='▸ язык: %s' ;;
    kk:install.lang) text='▸ тіл: %s' ;;

    uk:install.noNode) text='✖ node не знайдено' ;;
    en:install.noNode) text='✖ node not found' ;;
    cs:install.noNode) text='✖ node nenalezen' ;;
    ru:install.noNode) text='✖ node не найден' ;;
    kk:install.noNode) text='✖ node табылмады' ;;

    uk:install.noXcodegen) text='✖ xcodegen не знайдено: brew install xcodegen' ;;
    en:install.noXcodegen) text='✖ xcodegen not found: brew install xcodegen' ;;
    cs:install.noXcodegen) text='✖ xcodegen nenalezen: brew install xcodegen' ;;
    ru:install.noXcodegen) text='✖ xcodegen не найден: brew install xcodegen' ;;
    kk:install.noXcodegen) text='✖ xcodegen табылмады: brew install xcodegen' ;;

    uk:install.tmuxInstall) text='▸ ставлю tmux (без нього не можна писати в сесії)' ;;
    en:install.tmuxInstall) text='▸ installing tmux (without it nothing can type into a session)' ;;
    cs:install.tmuxInstall) text='▸ instaluji tmux (bez něj nelze psát do relací)' ;;
    ru:install.tmuxInstall) text='▸ ставлю tmux (без него нельзя писать в сессии)' ;;
    kk:install.tmuxInstall) text='▸ tmux орнатамын (онсыз сессияға жазу мүмкін емес)' ;;

    uk:install.tmuxMissing) text='  ⚠ tmux немає — скріншоти з браузера, режим і модель із програми не працюватимуть.' ;;
    en:install.tmuxMissing) text='  ⚠ no tmux — screenshots from the browser and mode or model from the app will not work.' ;;
    cs:install.tmuxMissing) text='  ⚠ tmux chybí — snímky z prohlížeče ani režim a model z aplikace nebudou fungovat.' ;;
    ru:install.tmuxMissing) text='  ⚠ tmux нет — скриншоты из браузера, режим и модель из программы работать не будут.' ;;
    kk:install.tmuxMissing) text='  ⚠ tmux жоқ — браузерден скриншоттар, бағдарламадан режим мен модель жұмыс істемейді.' ;;

    uk:install.tmuxHow) text='    Постав його: brew install tmux' ;;
    en:install.tmuxHow) text='    Install it: brew install tmux' ;;
    cs:install.tmuxHow) text='    Nainstaluj ho: brew install tmux' ;;
    ru:install.tmuxHow) text='    Поставь его: brew install tmux' ;;
    kk:install.tmuxHow) text='    Орнат: brew install tmux' ;;

    uk:install.notifierInstall) text='▸ ставлю terminal-notifier' ;;
    en:install.notifierInstall) text='▸ installing terminal-notifier' ;;
    cs:install.notifierInstall) text='▸ instaluji terminal-notifier' ;;
    ru:install.notifierInstall) text='▸ ставлю terminal-notifier' ;;
    kk:install.notifierInstall) text='▸ terminal-notifier орнатамын' ;;

    uk:install.notifierMissing) text='  ⚠ terminal-notifier немає — банери підуть через osascript' ;;
    en:install.notifierMissing) text='  ⚠ no terminal-notifier — banners will go through osascript' ;;
    cs:install.notifierMissing) text='  ⚠ terminal-notifier chybí — oznámení půjdou přes osascript' ;;
    ru:install.notifierMissing) text='  ⚠ terminal-notifier нет — баннеры пойдут через osascript' ;;
    kk:install.notifierMissing) text='  ⚠ terminal-notifier жоқ — баннерлер osascript арқылы шығады' ;;

    uk:install.agents) text='▸ реєструю фонові процеси' ;;
    en:install.agents) text='▸ registering background services' ;;
    cs:install.agents) text='▸ registruji procesy na pozadí' ;;
    ru:install.agents) text='▸ регистрирую фоновые процессы' ;;
    kk:install.agents) text='▸ фондық процестерді тіркеймін' ;;

    uk:install.hooksClaude) text='▸ підключаю хуки Claude Code' ;;
    en:install.hooksClaude) text='▸ connecting Claude Code hooks' ;;
    cs:install.hooksClaude) text='▸ připojuji hooky Claude Code' ;;
    ru:install.hooksClaude) text='▸ подключаю хуки Claude Code' ;;
    kk:install.hooksClaude) text='▸ Claude Code хуктарын қосамын' ;;

    uk:install.hooksCodex) text='▸ підключаю хуки Codex' ;;
    en:install.hooksCodex) text='▸ connecting Codex hooks' ;;
    cs:install.hooksCodex) text='▸ připojuji hooky Codex' ;;
    ru:install.hooksCodex) text='▸ подключаю хуки Codex' ;;
    kk:install.hooksCodex) text='▸ Codex хуктарын қосамын' ;;

    uk:install.codexTrust) text='  Codex попросить підтвердити ці хуки при першому запуску — це нормально.' ;;
    en:install.codexTrust) text='  Codex will ask you to approve these hooks on first launch — that is expected.' ;;
    cs:install.codexTrust) text='  Codex tě při prvním spuštění požádá o potvrzení těchto hooků — to je v pořádku.' ;;
    ru:install.codexTrust) text='  Codex попросит подтвердить эти хуки при первом запуске — это нормально.' ;;
    kk:install.codexTrust) text='  Codex алғаш іске қосқанда бұл хуктарды растауды сұрайды — бұл қалыпты.' ;;

    uk:install.commands) text='▸ швидкі команди start / stop' ;;
    en:install.commands) text='▸ quick commands start / stop' ;;
    cs:install.commands) text='▸ rychlé příkazy start / stop' ;;
    ru:install.commands) text='▸ быстрые команды start / stop' ;;
    kk:install.commands) text='▸ жылдам командалар start / stop' ;;

    uk:install.commandsHave) text='  ✓ уже підключені в ~/.zshrc' ;;
    en:install.commandsHave) text='  ✓ already wired into ~/.zshrc' ;;
    cs:install.commandsHave) text='  ✓ už jsou zapojené v ~/.zshrc' ;;
    ru:install.commandsHave) text='  ✓ уже подключены в ~/.zshrc' ;;
    kk:install.commandsHave) text='  ✓ ~/.zshrc ішінде қосылып тұр' ;;

    uk:install.commandsOwn) text='  ⚠ у ~/.zshrc уже є своя start() — не чіпаю.' ;;
    en:install.commandsOwn) text='  ⚠ ~/.zshrc already has its own start() — leaving it alone.' ;;
    cs:install.commandsOwn) text='  ⚠ ~/.zshrc už má vlastní start() — nesahám na ni.' ;;
    ru:install.commandsOwn) text='  ⚠ в ~/.zshrc уже есть своя start() — не трогаю.' ;;
    kk:install.commandsOwn) text='  ⚠ ~/.zshrc ішінде өз start() бар — тиіспеймін.' ;;

    uk:install.commandsReplace) text='    Заміни її (разом зі stop і функціями-помічниками) одним рядком:' ;;
    en:install.commandsReplace) text='    Replace it (together with stop and its helper functions) with one line:' ;;
    cs:install.commandsReplace) text='    Nahraď ji (spolu se stop a pomocnými funkcemi) jedním řádkem:' ;;
    ru:install.commandsReplace) text='    Замени её (вместе со stop и вспомогательными функциями) одной строкой:' ;;
    kk:install.commandsReplace) text='    Оны (stop және көмекші функциялармен бірге) бір жолмен ауыстыр:' ;;

    uk:install.commandsAdded) text='  ✓ додано в ~/.zshrc — діє в нових вкладках термінала' ;;
    en:install.commandsAdded) text='  ✓ added to ~/.zshrc — works in new terminal tabs' ;;
    cs:install.commandsAdded) text='  ✓ přidáno do ~/.zshrc — funguje v nových kartách terminálu' ;;
    ru:install.commandsAdded) text='  ✓ добавлено в ~/.zshrc — работает в новых вкладках терминала' ;;
    kk:install.commandsAdded) text='  ✓ ~/.zshrc ішіне қосылды — терминалдың жаңа қойындыларында жұмыс істейді' ;;

    uk:install.notZsh) text='  ⚠ оболонка не zsh (%s) — start і stop написані для zsh' ;;
    en:install.notZsh) text='  ⚠ the shell is not zsh (%s) — start and stop are written for zsh' ;;
    cs:install.notZsh) text='  ⚠ shell není zsh (%s) — start a stop jsou napsané pro zsh' ;;
    ru:install.notZsh) text='  ⚠ оболочка не zsh (%s) — start и stop написаны для zsh' ;;
    kk:install.notZsh) text='  ⚠ қабық zsh емес (%s) — start пен stop zsh үшін жазылған' ;;

    uk:install.cards) text='▸ картки відповідей (мод reply-cards)' ;;
    en:install.cards) text='▸ reply cards (the reply-cards mod)' ;;
    cs:install.cards) text='▸ karty odpovědí (mod reply-cards)' ;;
    ru:install.cards) text='▸ карточки ответов (мод reply-cards)' ;;
    kk:install.cards) text='▸ жауап карточкалары (reply-cards моды)' ;;

    uk:install.cardsOn) text='  ✓ мод увімкнено — діє в нових сесіях Claude Code' ;;
    en:install.cardsOn) text='  ✓ mod enabled — takes effect in new Claude Code sessions' ;;
    cs:install.cardsOn) text='  ✓ mod zapnut — platí v nových relacích Claude Code' ;;
    ru:install.cardsOn) text='  ✓ мод включён — действует в новых сессиях Claude Code' ;;
    kk:install.cardsOn) text='  ✓ мод қосылды — Claude Code жаңа сессияларында жұмыс істейді' ;;

    uk:install.cardsFailed) text='  ⚠ не вдалося поставити мод. Руками: claude plugin install reply-cards@laserbeak' ;;
    en:install.cardsFailed) text='  ⚠ could not install the mod. By hand: claude plugin install reply-cards@laserbeak' ;;
    cs:install.cardsFailed) text='  ⚠ mod se nepodařilo nainstalovat. Ručně: claude plugin install reply-cards@laserbeak' ;;
    ru:install.cardsFailed) text='  ⚠ не удалось поставить мод. Вручную: claude plugin install reply-cards@laserbeak' ;;
    kk:install.cardsFailed) text='  ⚠ модты орнату мүмкін болмады. Қолмен: claude plugin install reply-cards@laserbeak' ;;

    uk:install.cardsNoClaude) text='  ⚠ claude не знайдено — мод не поставлено' ;;
    en:install.cardsNoClaude) text='  ⚠ claude not found — mod not installed' ;;
    cs:install.cardsNoClaude) text='  ⚠ claude nenalezen — mod není nainstalovaný' ;;
    ru:install.cardsNoClaude) text='  ⚠ claude не найден — мод не поставлен' ;;
    kk:install.cardsNoClaude) text='  ⚠ claude табылмады — мод орнатылмады' ;;

    uk:install.check) text='▸ перевіряю' ;;
    en:install.check) text='▸ checking' ;;
    cs:install.check) text='▸ kontroluji' ;;
    ru:install.check) text='▸ проверяю' ;;
    kk:install.check) text='▸ тексеремін' ;;

    uk:install.daemonOk) text='  ✓ демон живий на порті %s' ;;
    en:install.daemonOk) text='  ✓ the daemon is alive on port %s' ;;
    cs:install.daemonOk) text='  ✓ démon běží na portu %s' ;;
    ru:install.daemonOk) text='  ✓ демон жив на порту %s' ;;
    kk:install.daemonOk) text='  ✓ демон %s портында жұмыс істеп тұр' ;;

    uk:install.daemonDown) text='  ✖ демон не відповідає. Дивись %s' ;;
    en:install.daemonDown) text='  ✖ the daemon is not responding. See %s' ;;
    cs:install.daemonDown) text='  ✖ démon neodpovídá. Podívej se do %s' ;;
    ru:install.daemonDown) text='  ✖ демон не отвечает. Смотри %s' ;;
    kk:install.daemonDown) text='  ✖ демон жауап бермейді. Қара: %s' ;;

    uk:install.ext) text='▸ розширення для браузера (необовʼязкове)' ;;
    en:install.ext) text='▸ browser extension (optional)' ;;
    cs:install.ext) text='▸ rozšíření pro prohlížeč (volitelné)' ;;
    ru:install.ext) text='▸ расширение для браузера (необязательное)' ;;
    kk:install.ext) text='▸ браузер кеңейтімі (міндетті емес)' ;;

    uk:install.extWhat) text='  Дає обвести зону на сторінці й надіслати її в сесію картинкою.' ;;
    en:install.extWhat) text='  Lets you outline a region of a page and send it to a session as a picture.' ;;
    cs:install.extWhat) text='  Umožní označit oblast na stránce a poslat ji do relace jako obrázek.' ;;
    ru:install.extWhat) text='  Позволяет обвести область на странице и отправить её в сессию картинкой.' ;;
    kk:install.extWhat) text='  Беттегі аймақты белгілеп, оны сессияға сурет ретінде жіберуге мүмкіндік береді.' ;;

    uk:install.extManual) text='  Ставиться руками — це три кліки, бо в Web Store його немає.' ;;
    en:install.extManual) text='  It is installed by hand — three clicks, since it is not in the Web Store.' ;;
    cs:install.extManual) text='  Instaluje se ručně — tři kliknutí, protože ve Web Store není.' ;;
    ru:install.extManual) text='  Ставится вручную — это три клика, потому что в Web Store его нет.' ;;
    kk:install.extManual) text='  Қолмен орнатылады — үш шерту, себебі ол Web Store ішінде жоқ.' ;;

    uk:install.extWhere) text='  Клади в той браузер, яким керує сесія (там, де стоїть Claude in Chrome):' ;;
    en:install.extWhere) text='  Put it in the browser your sessions drive (where Claude in Chrome lives):' ;;
    cs:install.extWhere) text='  Dej ho do prohlížeče, který relace ovládá (kde je Claude in Chrome):' ;;
    ru:install.extWhere) text='  Ставь в тот браузер, которым управляет сессия (где стоит Claude in Chrome):' ;;
    kk:install.extWhere) text='  Сессия басқаратын браузерге қой (Claude in Chrome тұрған жерге):' ;;

    uk:install.extStep1) text='    1. chrome://extensions (у Brave — brave://extensions)' ;;
    en:install.extStep1) text='    1. chrome://extensions (in Brave, brave://extensions)' ;;
    cs:install.extStep1) text='    1. chrome://extensions (v Brave brave://extensions)' ;;
    ru:install.extStep1) text='    1. chrome://extensions (в Brave — brave://extensions)' ;;
    kk:install.extStep1) text='    1. chrome://extensions (Brave ішінде — brave://extensions)' ;;

    uk:install.extStep1b) text='       →  увімкни «Режим розробника» (Developer mode)' ;;
    en:install.extStep1b) text='       →  turn on "Developer mode"' ;;
    cs:install.extStep1b) text='       →  zapni „Režim pro vývojáře“ (Developer mode)' ;;
    ru:install.extStep1b) text='       →  включи «Режим разработчика» (Developer mode)' ;;
    kk:install.extStep1b) text='       →  «Developer mode» режимін қос' ;;

    uk:install.extStep2) text='    2. «Завантажити розпаковане розширення» (Load unpacked)' ;;
    en:install.extStep2) text='    2. "Load unpacked"' ;;
    cs:install.extStep2) text='    2. „Načíst rozbalené“ (Load unpacked)' ;;
    ru:install.extStep2) text='    2. «Загрузить распакованное расширение» (Load unpacked)' ;;
    kk:install.extStep2) text='    2. «Load unpacked» батырмасы' ;;

    uk:install.extStep3) text='    3. вкажи теку:  %s' ;;
    en:install.extStep3) text='    3. pick the folder:  %s' ;;
    cs:install.extStep3) text='    3. vyber složku:  %s' ;;
    ru:install.extStep3) text='    3. укажи папку:  %s' ;;
    kk:install.extStep3) text='    3. буманы көрсет:  %s' ;;

    uk:install.extThen) text='  Далі — ⌘⇧E на будь-якій сторінці.' ;;
    en:install.extThen) text='  Then press ⌘⇧E on any page.' ;;
    cs:install.extThen) text='  Pak stiskni ⌘⇧E na libovolné stránce.' ;;
    ru:install.extThen) text='  Дальше — ⌘⇧E на любой странице.' ;;
    kk:install.extThen) text='  Әрі қарай — кез келген бетте ⌘⇧E.' ;;

    uk:install.done) text='Готово.' ;;
    en:install.done) text='Done.' ;;
    cs:install.done) text='Hotovo.' ;;
    ru:install.done) text='Готово.' ;;
    kk:install.done) text='Дайын.' ;;

    uk:install.doneApp) text='  • Програма:  %s' ;;
    en:install.doneApp) text='  • App:       %s' ;;
    cs:install.doneApp) text='  • Aplikace:  %s' ;;
    ru:install.doneApp) text='  • Программа: %s' ;;
    kk:install.doneApp) text='  • Бағдарлама: %s' ;;

    uk:install.doneRules) text='  • Правила:   %s  (перечитується на льоту)' ;;
    en:install.doneRules) text='  • Rules:     %s  (re-read on the fly)' ;;
    cs:install.doneRules) text='  • Pravidla:  %s  (načítá se průběžně)' ;;
    ru:install.doneRules) text='  • Правила:   %s  (перечитывается на лету)' ;;
    kk:install.doneRules) text='  • Ережелер:  %s  (өзгерісі бірден оқылады)' ;;

    uk:install.doneLog) text='  • Лог:       %s' ;;
    en:install.doneLog) text='  • Log:       %s' ;;
    cs:install.doneLog) text='  • Log:       %s' ;;
    ru:install.doneLog) text='  • Лог:       %s' ;;
    kk:install.doneLog) text='  • Журнал:    %s' ;;

    uk:install.doneErrors) text='  • Збої:      %s  (npm run errors)' ;;
    en:install.doneErrors) text='  • Errors:    %s  (npm run errors)' ;;
    cs:install.doneErrors) text='  • Chyby:     %s  (npm run errors)' ;;
    ru:install.doneErrors) text='  • Сбои:      %s  (npm run errors)' ;;
    kk:install.doneErrors) text='  • Қателер:   %s  (npm run errors)' ;;

    uk:install.doneHooks) text='Хуки почнуть діяти в НОВИХ сесіях Claude Code — перезапусти сесію.' ;;
    en:install.doneHooks) text='Hooks take effect in NEW Claude Code sessions — restart your session.' ;;
    cs:install.doneHooks) text='Hooky začnou fungovat v NOVÝCH relacích Claude Code — restartuj relaci.' ;;
    ru:install.doneHooks) text='Хуки начнут действовать в НОВЫХ сессиях Claude Code — перезапусти сессию.' ;;
    kk:install.doneHooks) text='Хуктар Claude Code-тың ЖАҢА сессияларында іске қосылады — сессияны қайта іске қос.' ;;

    uk:uninstall.agents) text='▸ зупиняю фонові процеси' ;;
    en:uninstall.agents) text='▸ stopping background services' ;;
    cs:uninstall.agents) text='▸ zastavuji procesy na pozadí' ;;
    ru:uninstall.agents) text='▸ останавливаю фоновые процессы' ;;
    kk:uninstall.agents) text='▸ фондық процестерді тоқтатамын' ;;

    uk:uninstall.agentsDone) text='  ✓ агенти прибрано' ;;
    en:uninstall.agentsDone) text='  ✓ agents removed' ;;
    cs:uninstall.agentsDone) text='  ✓ agenti odstraněni' ;;
    ru:uninstall.agentsDone) text='  ✓ агенты убраны' ;;
    kk:uninstall.agentsDone) text='  ✓ агенттер алынды' ;;

    uk:uninstall.hooks) text='▸ прибираю хуки з %s' ;;
    en:uninstall.hooks) text='▸ removing hooks from %s' ;;
    cs:uninstall.hooks) text='▸ odstraňuji hooky z %s' ;;
    ru:uninstall.hooks) text='▸ убираю хуки из %s' ;;
    kk:uninstall.hooks) text='▸ %s ішінен хуктарды аламын' ;;

    uk:uninstall.cards) text='▸ прибираю мод reply-cards' ;;
    en:uninstall.cards) text='▸ removing the reply-cards mod' ;;
    cs:uninstall.cards) text='▸ odstraňuji mod reply-cards' ;;
    ru:uninstall.cards) text='▸ убираю мод reply-cards' ;;
    kk:uninstall.cards) text='▸ reply-cards модын аламын' ;;

    uk:uninstall.zshrc) text='▸ прибираю start / stop з ~/.zshrc' ;;
    en:uninstall.zshrc) text='▸ removing start / stop from ~/.zshrc' ;;
    cs:uninstall.zshrc) text='▸ odstraňuji start / stop z ~/.zshrc' ;;
    ru:uninstall.zshrc) text='▸ убираю start / stop из ~/.zshrc' ;;
    kk:uninstall.zshrc) text='▸ ~/.zshrc ішінен start / stop аламын' ;;

    uk:uninstall.removedApp) text='▸ видалив %s' ;;
    en:uninstall.removedApp) text='▸ removed %s' ;;
    cs:uninstall.removedApp) text='▸ smazáno %s' ;;
    ru:uninstall.removedApp) text='▸ удалил %s' ;;
    kk:uninstall.removedApp) text='▸ %s жойылды' ;;

    uk:uninstall.done) text='Готово. Дані лишились у ~/.laserbeak (config, логи, історія, копія .zshrc).' ;;
    en:uninstall.done) text='Done. Your data stays in ~/.laserbeak (config, logs, history, a copy of .zshrc).' ;;
    cs:uninstall.done) text='Hotovo. Data zůstala v ~/.laserbeak (config, logy, historie, kopie .zshrc).' ;;
    ru:uninstall.done) text='Готово. Данные остались в ~/.laserbeak (config, логи, история, копия .zshrc).' ;;
    kk:uninstall.done) text='Дайын. Деректер ~/.laserbeak ішінде қалды (config, журналдар, тарих, .zshrc көшірмесі).' ;;

    uk:build.team) text='▸ підписую як команда %s' ;;
    en:build.team) text='▸ signing as team %s' ;;
    cs:build.team) text='▸ podepisuji jako tým %s' ;;
    ru:build.team) text='▸ подписываю как команда %s' ;;
    kk:build.team) text='▸ %s командасы ретінде қол қоямын' ;;

    uk:build.project) text='▸ генерую Xcode-проєкт' ;;
    en:build.project) text='▸ generating the Xcode project' ;;
    cs:build.project) text='▸ generuji projekt Xcode' ;;
    ru:build.project) text='▸ генерирую Xcode-проект' ;;
    kk:build.project) text='▸ Xcode жобасын жасаймын' ;;

    uk:build.app) text='▸ збираю Laserbeak.app' ;;
    en:build.app) text='▸ building Laserbeak.app' ;;
    cs:build.app) text='▸ sestavuji Laserbeak.app' ;;
    ru:build.app) text='▸ собираю Laserbeak.app' ;;
    kk:build.app) text='▸ Laserbeak.app жинаймын' ;;

    uk:build.failed) text='  ✖ збірка впала. Деталі:' ;;
    en:build.failed) text='  ✖ the build failed. Details:' ;;
    cs:build.failed) text='  ✖ sestavení selhalo. Podrobnosti:' ;;
    ru:build.failed) text='  ✖ сборка упала. Подробности:' ;;
    kk:build.failed) text='  ✖ жинау сәтсіз аяқталды. Толығырақ:' ;;

    uk:build.notFound) text='  ✖ не знайшов %s' ;;
    en:build.notFound) text='  ✖ could not find %s' ;;
    cs:build.notFound) text='  ✖ nenašel jsem %s' ;;
    ru:build.notFound) text='  ✖ не нашёл %s' ;;
    kk:build.notFound) text='  ✖ %s табылмады' ;;

    uk:team.none) text='✖ не знайшов сертифіката Apple Development у звʼязці ключів.' ;;
    en:team.none) text='✖ no Apple Development certificate found in the keychain.' ;;
    cs:team.none) text='✖ v klíčence jsem nenašel certifikát Apple Development.' ;;
    ru:team.none) text='✖ не нашёл сертификата Apple Development в связке ключей.' ;;
    kk:team.none) text='✖ кілттер жинағынан Apple Development сертификаты табылмады.' ;;

    uk:team.why) text='  Він безкоштовний і потрібен саме для збірки: з ad-hoc підписом macOS мовчки відмовляє програмі в сповіщеннях.' ;;
    en:team.why) text='  It is free and needed for the build: with an ad-hoc signature macOS silently denies the app notifications.' ;;
    cs:team.why) text='  Je zdarma a je potřeba právě pro sestavení: s ad-hoc podpisem macOS aplikaci tiše odepře oznámení.' ;;
    ru:team.why) text='  Он бесплатный и нужен именно для сборки: с ad-hoc подписью macOS молча отказывает программе в уведомлениях.' ;;
    kk:team.why) text='  Ол тегін және дәл жинау үшін керек: ad-hoc қолтаңбамен macOS бағдарламаға хабарландыруларды үнсіз бермейді.' ;;

    uk:team.how) text='  Як отримати:' ;;
    en:team.how) text='  How to get one:' ;;
    cs:team.how) text='  Jak ho získat:' ;;
    ru:team.how) text='  Как получить:' ;;
    kk:team.how) text='  Қалай алуға болады:' ;;

    uk:team.step1) text='    1. Xcode → Settings → Accounts → «+» → Apple ID (звичайний, безкоштовний)' ;;
    en:team.step1) text='    1. Xcode → Settings → Accounts → "+" → Apple ID (a regular, free one)' ;;
    cs:team.step1) text='    1. Xcode → Settings → Accounts → „+“ → Apple ID (běžné, zdarma)' ;;
    ru:team.step1) text='    1. Xcode → Settings → Accounts → «+» → Apple ID (обычный, бесплатный)' ;;
    kk:team.step1) text='    1. Xcode → Settings → Accounts → «+» → Apple ID (кәдімгі, тегін)' ;;

    uk:team.step2) text='    2. вибери акаунт → Manage Certificates → «+» → Apple Development' ;;
    en:team.step2) text='    2. pick the account → Manage Certificates → "+" → Apple Development' ;;
    cs:team.step2) text='    2. vyber účet → Manage Certificates → „+“ → Apple Development' ;;
    ru:team.step2) text='    2. выбери аккаунт → Manage Certificates → «+» → Apple Development' ;;
    kk:team.step2) text='    2. аккаунтты таңда → Manage Certificates → «+» → Apple Development' ;;

    uk:team.again) text='  Далі просто повтори збірку.' ;;
    en:team.again) text='  Then just run the build again.' ;;
    cs:team.again) text='  Pak sestavení jen zopakuj.' ;;
    ru:team.again) text='  Дальше просто повтори сборку.' ;;
    kk:team.again) text='  Содан кейін жинауды қайтала.' ;;

    uk:patch.badJson) text='✖ %s не є валідним JSON: %s' ;;
    en:patch.badJson) text='✖ %s is not valid JSON: %s' ;;
    cs:patch.badJson) text='✖ %s není platný JSON: %s' ;;
    ru:patch.badJson) text='✖ %s — невалидный JSON: %s' ;;
    kk:patch.badJson) text='✖ %s жарамды JSON емес: %s' ;;

    uk:patch.fixManually) text='  Виправ файл вручну і запусти ще раз — я нічого не чіпав.' ;;
    en:patch.fixManually) text='  Fix the file by hand and run again — nothing was changed.' ;;
    cs:patch.fixManually) text='  Oprav soubor ručně a spusť znovu — nic jsem neměnil.' ;;
    ru:patch.fixManually) text='  Исправь файл вручную и запусти ещё раз — я ничего не трогал.' ;;
    kk:patch.fixManually) text='  Файлды қолмен түзет те, қайта іске қос — мен ештеңе өзгертпедім.' ;;

    uk:patch.backup) text='  бекап: %s' ;;
    en:patch.backup) text='  backup: %s' ;;
    cs:patch.backup) text='  záloha: %s' ;;
    ru:patch.backup) text='  бэкап: %s' ;;
    kk:patch.backup) text='  сақтық көшірме: %s' ;;

    uk:patch.nothing) text='  %s немає — знімати нічого' ;;
    en:patch.nothing) text='  %s does not exist — nothing to remove' ;;
    cs:patch.nothing) text='  %s neexistuje — není co odebrat' ;;
    ru:patch.nothing) text='  %s нет — снимать нечего' ;;
    kk:patch.nothing) text='  %s жоқ — алатын ештеңе жоқ' ;;

    uk:patch.removed) text='  ✓ хуки laserbeak прибрано' ;;
    en:patch.removed) text='  ✓ laserbeak hooks removed' ;;
    cs:patch.removed) text='  ✓ hooky laserbeak odstraněny' ;;
    ru:patch.removed) text='  ✓ хуки laserbeak убраны' ;;
    kk:patch.removed) text='  ✓ laserbeak хуктары алынды' ;;

    uk:patch.added) text='  ✓ хуки прописано (%s)' ;;
    en:patch.added) text='  ✓ hooks written (%s)' ;;
    cs:patch.added) text='  ✓ hooky zapsány (%s)' ;;
    ru:patch.added) text='  ✓ хуки прописаны (%s)' ;;
    kk:patch.added) text='  ✓ хуктар жазылды (%s)' ;;

    uk:patch.statusline) text='  ✓ рядок стану йде через Laserbeak (ліміти підписки); твоя команда — у %s' ;;
    en:patch.statusline) text='  ✓ status line goes through Laserbeak (plan limits); your command is in %s' ;;
    cs:patch.statusline) text='  ✓ stavový řádek jde přes Laserbeak (limity předplatného); tvůj příkaz je v %s' ;;
    ru:patch.statusline) text='  ✓ строка состояния идёт через Laserbeak (лимиты подписки); твоя команда — в %s' ;;
    kk:patch.statusline) text='  ✓ күй жолағы Laserbeak арқылы өтеді (жазылым лимиттері); сіздің командаңыз — %s ішінде' ;;

    uk:ext.copied) text='Теку скопійовано в буфер:' ;;
    en:ext.copied) text='Folder path copied to the clipboard:' ;;
    cs:ext.copied) text='Cesta ke složce je ve schránce:' ;;
    ru:ext.copied) text='Путь к папке скопирован в буфер:' ;;
    kk:ext.copied) text='Бума жолы алмасу буферіне көшірілді:' ;;

    uk:ext.how) text='chrome://extensions → «Режим розробника» (Developer mode) → «Завантажити розпаковане розширення» (Load unpacked) → ⌘V' ;;
    en:ext.how) text='chrome://extensions → "Developer mode" → "Load unpacked" → ⌘V' ;;
    cs:ext.how) text='chrome://extensions → „Režim pro vývojáře“ (Developer mode) → „Načíst rozbalené“ (Load unpacked) → ⌘V' ;;
    ru:ext.how) text='chrome://extensions → «Режим разработчика» (Developer mode) → «Загрузить распакованное расширение» (Load unpacked) → ⌘V' ;;
    kk:ext.how) text='chrome://extensions → «Developer mode» → «Load unpacked» → ⌘V' ;;
  esac

  # Ключа немає в таблиці — краще показати сам ключ, ніж порожній рядок.
  [ -n "$text" ] || text="$key"
  # shellcheck disable=SC2059
  printf -- "$text" "$@"
}

say() { lb_t "$@"; printf '\n'; }
