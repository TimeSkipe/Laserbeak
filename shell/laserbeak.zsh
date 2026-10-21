# Швидкі команди Laserbeak для zsh: start і stop.
#
# Підключаються одним рядком у ~/.zshrc — його дописує scripts/install.sh:
#
#   source "/шлях/до/laserbeak/shell/laserbeak.zsh"
#
# Без start сесія Claude Code працює, але Laserbeak не може передати в неї
# ані скріншот із браузера, ані перемкнути режим чи модель: писати можна
# лише в термінал, який тримаєш сам, а вкладку WebStorm тримає WebStorm.
# start ставить посередника — tmux — і передає мітку сесії.
#
#   start                    Claude Code, мітка з tty цієї вкладки
#   start "назва"            Claude Code з міткою
#   start codex "назва"      Codex — так само в tmux, так само з міткою
#   start api "полагодь …"   свій перший запит замість прохання про docs/
#   start -n …               без прохання прочитати документацію
#
#   stop                     що живе і скільки їсть
#   stop "назва"             убити сесію з цією міткою
#   stop -a                  убити всі відчеплені
#
# Тексти — мовою, вибраною в Laserbeak: її віддає демон, а коли він лежить —
# ~/.laserbeak/config.json. Перший запит у сесію теж нею: це твої слова.

# Де лежить репозиторій: звідси беремо tmux.conf.
typeset -g _LB_ROOT="${${(%):-%x}:A:h:h}"

# Помічники — з двома підкресленнями, не з одним: Claude Code, знімаючи
# оболонку для команд `!`, викидає функції з одним `_` (так він минає
# completion-функції zsh). З одним `_` там лишались би start і stop без
# своїх помічників: «command not found: _lb_lang».

# Мова Laserbeak — уже розвʼязана демоном ("auto" → мова системи).
__lb_lang() {
  local config="$HOME/.laserbeak/config.json" port=8787 json
  json="$(cat "$config" 2>/dev/null)"
  [[ "$json" =~ '"port": *([0-9]+)' ]] && port="$match[1]"

  # Перше збіжне в /settings — або явний вибір, або вже розвʼязане "auto".
  local reply
  reply="$(curl -s -m 1 "http://127.0.0.1:${port}/settings" 2>/dev/null)"
  if [[ "$reply" =~ '"language":"(uk|en|cs|ru|kk)"' ]]; then
    print -r -- "$match[1]"
  elif [[ "$json" =~ '"language": *"(uk|en|cs|ru|kk)"' ]]; then
    print -r -- "$match[1]"
  else
    print en
  fi
}

# Текст за ключем. Мову рахують один раз на виклик start чи stop
# (_LB_LANG), а не на кожен рядок — це запит до демона.
__lb_t() {
  local key="$1"; shift
  local text
  case "${_LB_LANG:-en}:$key" in
    uk:docs.ending) text='Потім у кількох рядках скажи, що зрозумів, і чекай на мій запит: поки нічого не міняй.' ;;
    en:docs.ending) text='Then tell me in a few lines what you understood and wait for my request: do not change anything yet.' ;;
    cs:docs.ending) text='Pak mi v pár řádcích řekni, co jsi pochopil, a počkej na můj požadavek: zatím nic neměň.' ;;
    ru:docs.ending) text='Потом в нескольких строках скажи, что понял, и жди моего запроса: пока ничего не меняй.' ;;
    kk:docs.ending) text='Содан кейін бірнеше жолмен не түсінгеніңді айт та, менің сұрауымды күт: әзірге ештеңе өзгертпе.' ;;

    uk:docs.lead) text='Спершу розберись із документацією проєкту' ;;
    en:docs.lead) text='First get to know the project documentation' ;;
    cs:docs.lead) text='Nejdřív se seznam s dokumentací projektu' ;;
    ru:docs.lead) text='Сначала разберись с документацией проекта' ;;
    kk:docs.lead) text='Алдымен жобаның құжаттамасымен таныс' ;;

    uk:docs.leadRules) text='Спершу прочитай %s, потім розберись із документацією проєкту' ;;
    en:docs.leadRules) text='First read %s, then get to know the project documentation' ;;
    cs:docs.leadRules) text='Nejdřív si přečti %s, pak se seznam s dokumentací projektu' ;;
    ru:docs.leadRules) text='Сначала прочитай %s, потом разберись с документацией проекта' ;;
    kk:docs.leadRules) text='Алдымен %s файлын оқы, содан кейін жобаның құжаттамасымен таныс' ;;

    uk:docs.heavy) text='у docs/ %d файлів на %d КБ — усе підряд читати не треба. Подивись перелік і прочитай те, з чого варто почати; якщо CLAUDE.md називає порядок — тримайся його.' ;;
    en:docs.heavy) text='docs/ holds %d files, %d KB — no need to read them all. Look at the list and read what is worth starting with; if CLAUDE.md names an order, follow it.' ;;
    cs:docs.heavy) text='v docs/ je %d souborů, %d KB — není třeba číst všechno. Projdi seznam a přečti, čím má smysl začít; pokud CLAUDE.md určuje pořadí, drž se ho.' ;;
    ru:docs.heavy) text='в docs/ файлов: %d, всего %d КБ — читать всё подряд не нужно. Посмотри список и прочитай то, с чего стоит начать; если CLAUDE.md задаёт порядок — держись его.' ;;
    kk:docs.heavy) text='docs/ ішінде %d файл, барлығы %d КБ — бәрін қатарынан оқудың қажеті жоқ. Тізімді қара да, бастауға тұрарлығын оқы; егер CLAUDE.md оқу ретін көрсетсе — соны ұстан.' ;;

    uk:docs.read) text='Спершу прочитай документацію цього проєкту: %s. Якщо в ній сказано, у якому порядку читати — тримайся його.' ;;
    en:docs.read) text="First read this project's documentation: %s. If it says in what order to read, follow that." ;;
    cs:docs.read) text='Nejdřív si přečti dokumentaci tohoto projektu: %s. Pokud v ní stojí, v jakém pořadí číst, drž se toho.' ;;
    ru:docs.read) text='Сначала прочитай документацию этого проекта: %s. Если в ней сказано, в каком порядке читать, — держись этого.' ;;
    kk:docs.read) text='Алдымен осы жобаның құжаттамасын оқы: %s. Онда оқу реті айтылса — соны ұстан.' ;;

    uk:docs.rest) text='та решта .md у docs/' ;;
    en:docs.rest) text='and the rest of the .md files in docs/' ;;
    cs:docs.rest) text='a zbytek .md v docs/' ;;
    ru:docs.rest) text='и остальные .md в docs/' ;;
    kk:docs.rest) text='және docs/ ішіндегі басқа .md файлдары' ;;

    uk:codex.missing) text='Codex не знайдено: ні в PATH, ні в ChatGPT.app.' ;;
    en:codex.missing) text='Codex not found: neither on PATH nor in ChatGPT.app.' ;;
    cs:codex.missing) text='Codex nenalezen: není v PATH ani v ChatGPT.app.' ;;
    ru:codex.missing) text='Codex не найден: ни в PATH, ни в ChatGPT.app.' ;;
    kk:codex.missing) text='Codex табылмады: PATH ішінде де, ChatGPT.app ішінде де жоқ.' ;;

    uk:tmux.missing) text='tmux не встановлено.' ;;
    en:tmux.missing) text='tmux is not installed.' ;;
    cs:tmux.missing) text='tmux není nainstalovaný.' ;;
    ru:tmux.missing) text='tmux не установлен.' ;;
    kk:tmux.missing) text='tmux орнатылмаған.' ;;

    uk:stop.none) text='Жодної сесії tmux не запущено.' ;;
    en:stop.none) text='No tmux sessions are running.' ;;
    cs:stop.none) text='Neběží žádná relace tmux.' ;;
    ru:stop.none) text='Ни одной сессии tmux не запущено.' ;;
    kk:stop.none) text='Іске қосылған tmux сессиясы жоқ.' ;;

    uk:stop.noDetached) text='Відчеплених сесій немає.' ;;
    en:stop.noDetached) text='No detached sessions.' ;;
    cs:stop.noDetached) text='Žádné odpojené relace.' ;;
    ru:stop.noDetached) text='Отсоединённых сессий нет.' ;;
    kk:stop.noDetached) text='Ажыратылған сессия жоқ.' ;;

    uk:stop.label) text='МІТКА' ;;
    en:stop.label) text='LABEL' ;;
    cs:stop.label) text='ŠTÍTEK' ;;
    ru:stop.label) text='МЕТКА' ;;
    kk:stop.label) text='БЕЛГІ' ;;

    uk:stop.state) text='СТАН' ;;
    en:stop.state) text='STATE' ;;
    cs:stop.state) text='STAV' ;;
    ru:stop.state) text='СОСТОЯНИЕ' ;;
    kk:stop.state) text='КҮЙІ' ;;

    uk:stop.memory) text="ПАМ'ЯТЬ" ;;
    en:stop.memory) text='MEMORY' ;;
    cs:stop.memory) text='PAMĚŤ' ;;
    ru:stop.memory) text='ПАМЯТЬ' ;;
    kk:stop.memory) text='ЖАДЫ' ;;

    uk:stop.tab) text='вкладка' ;;
    en:stop.tab) text='tab' ;;
    cs:stop.tab) text='karta' ;;
    ru:stop.tab) text='вкладка' ;;
    kk:stop.tab) text='қойынды' ;;

    uk:stop.background) text='у фоні' ;;
    en:stop.background) text='background' ;;
    cs:stop.background) text='na pozadí' ;;
    ru:stop.background) text='в фоне' ;;
    kk:stop.background) text='фонда' ;;

    uk:stop.mb) text='МБ' ;;
    en:stop.mb|cs:stop.mb) text='MB' ;;
    ru:stop.mb) text='МБ' ;;
    kk:stop.mb) text='МБ' ;;

    uk:stop.hint) text='Убити:  stop <мітка>   або   stop -a  (усі, що у фоні)' ;;
    en:stop.hint) text='Kill:  stop <label>   or   stop -a  (all in the background)' ;;
    cs:stop.hint) text='Ukončit:  stop <štítek>   nebo   stop -a  (všechny na pozadí)' ;;
    ru:stop.hint) text='Убить:  stop <метка>   или   stop -a  (все, что в фоне)' ;;
    kk:stop.hint) text='Жою:  stop <белгі>   немесе   stop -a  (фондағылардың бәрі)' ;;

    uk:stop.notFound) text='Сесії «%s» немає. Що є — покаже просто stop.' ;;
    en:stop.notFound) text='No session “%s”. Plain stop shows what there is.' ;;
    cs:stop.notFound) text='Relace „%s“ neexistuje. Co běží, ukáže samotné stop.' ;;
    ru:stop.notFound) text='Сессии «%s» нет. Что есть — покажет просто stop.' ;;
    kk:stop.notFound) text='«%s» сессиясы жоқ. Не бар екенін жай stop көрсетеді.' ;;

    uk:stop.killed) text='убито: %s' ;;
    en:stop.killed) text='killed: %s' ;;
    cs:stop.killed) text='ukončeno: %s' ;;
    ru:stop.killed) text='убита: %s' ;;
    kk:stop.killed) text='жойылды: %s' ;;

    uk:stop.failed) text='не вдалося вбити: %s' ;;
    en:stop.failed) text='could not kill: %s' ;;
    cs:stop.failed) text='nepodařilo se ukončit: %s' ;;
    ru:stop.failed) text='не удалось убить: %s' ;;
    kk:stop.failed) text='жою мүмкін болмады: %s' ;;

    *) text="$key" ;;
  esac
  printf -- "$text" "$@"
}

# Перший запит: прочитати документацію проєкту.
#
# Попросити про це легко забути, а сесія без docs/ починає з припущень.
# Тому start просить сам — і називає тільки ті файли, які в проєкті
# справді лежать. CLAUDE.md у переліку немає: Claude Code підвантажує
# його сам, просити вдруге означало б читати те, що вже в контексті.
#
# Codex — інша справа: він підвантажує AGENTS.md, а CLAUDE.md не бачить.
# Тож для нього (`__lb_docs_prompt codex`) CLAUDE.md іде першим, якщо
# AGENTS.md у проєкті немає, — інакше Codex не знатиме правил проєкту.
#
# Корінь шукаємо вгору від поточної теки (.git або CLAUDE.md): сесію
# часто відкривають із підтеки, а документація лежить у корені.
__lb_docs_prompt() {
  local agent="${1:-claude}"
  local root="$PWD"
  while [ "$root" != "/" ] && [ ! -e "$root/.git" ] && [ ! -e "$root/CLAUDE.md" ]; do
    root="${root:h}"
  done
  [ "$root" = "/" ] && root="$PWD"

  local rules=""
  if [ "$agent" = codex ] && [ -f "$root/CLAUDE.md" ] && [ ! -e "$root/AGENTS.md" ]; then
    rules="$root/CLAUDE.md"
    rules="${rules#$PWD/}"
  fi

  # README беремо тільки тоді, коли docs/ немає. Там, де тека є, README
  # переказує її для користувача — а це десятки тисяч токенів за дубль
  # того, що вже прочитано. Немає docs/ — README єдина документація.
  local -a files
  local from=docs f
  files=( "$root"/docs/**/*.md(N) )
  if (( ! ${#files} )); then
    files=( "$root"/README.md(N) )
    from=readme
  fi
  (( ${#files} )) || [ -n "$rules" ] || return 1

  local ending="$(__lb_t docs.ending)"

  # Скільки все це важить. 120 КБ — це приблизно 40k токенів, пʼята
  # частина вікна на 200k: стільки віддати не шкода. Але docs/ буває й
  # на пів мегабайта, і тоді прохання «прочитай усе» зʼїдає вікно ще
  # до першого запиту. Там, де важко, чесніше дати агентові подивитись
  # перелік і вибрати самому — CLAUDE.md у нього вже в контексті.
  if [ "$from" = docs ]; then
    local -i weight=0 size
    for f in "${files[@]}"; do
      size=$(stat -f%z "$f" 2>/dev/null) || size=0
      (( weight += size ))
    done
    if (( weight > 122880 )); then
      local lead="$(__lb_t docs.lead)"
      [ -n "$rules" ] && lead="$(__lb_t docs.leadRules "$rules")"
      print -r -- "${lead}: $(__lb_t docs.heavy ${#files} $(( (weight + 512) / 1024 ))) ${ending}"
      return 0
    fi
  fi

  local -a names
  [ -n "$rules" ] && names=( "$rules" )
  for f in "${files[@]}"; do names+=( "${f#$PWD/}" ); done

  # Довгий перелік сам стає стіною тексту — тоді чесніше назвати теку.
  local list="${(j:, :)names}"
  (( ${#names} > 10 )) && list="${(j:, :)names[1,8]} $(__lb_t docs.rest)"

  # Один рядок: у сесію це летить як один аргумент, і кожен перенос
  # там був би окремою відправкою.
  print -r -- "$(__lb_t docs.read "$list") ${ending}"
}

start() {
  local _LB_LANG="$(__lb_lang)"
  local docs=1 agent=claude
  while (( $# )); do
    case "$1" in
      -n|--no-docs) docs=0; shift ;;
      # Лише перше «codex» — це агент: `start codex codex` дає Codex-сесію
      # з міткою codex, а не порожню.
      codex) [ "$agent" = codex ] && break; agent=codex; shift ;;
      *) break ;;
    esac
  done

  # Codex окремо в PATH буває не завжди — частіше він вбудований у
  # ChatGPT.app. Хуки Laserbeak він запускає зі свого процесу в панелі,
  # тож мітка й адреса панелі доходять до демона так само, як від claude.
  local -a cmd
  if [ "$agent" = codex ]; then
    local bin="$(command -v codex 2>/dev/null)"
    [ -x "$bin" ] || bin="/Applications/ChatGPT.app/Contents/Resources/codex"
    if [ ! -x "$bin" ]; then
      print -u2 -- "$(__lb_t codex.missing)"
      return 1
    fi
    cmd=( "$bin" )
  else
    cmd=( claude )
  fi

  local label="$1"
  if [ -z "$label" ]; then
    label="$(basename "$(tty 2>/dev/null)" 2>/dev/null)"
    case "$label" in ""|*" "*) label="$agent" ;; esac
  fi

  # Свій перший запит важливіший за наш: `start api "полагодь збірку"`
  # має піти саме з тим текстом, який набрали.
  local -a args
  args=( "${@:2}" )
  if (( docs )) && (( ${#args} == 0 )); then
    local intro
    intro="$(__lb_docs_prompt "$agent")" && args=( "$intro" )
  fi

  # Уже всередині tmux або його немає — запускаємо як раніше.
  if [ -n "$TMUX" ] || ! command -v tmux >/dev/null 2>&1; then
    CLAUDE_LABEL="$label" "${cmd[@]}" "${args[@]}"
    return
  fi

  # tmux.conf із репозиторію; старий у ~/.laserbeak — для тих, хто ставив
  # Laserbeak до того, як він туди переїхав.
  local conf="$_LB_ROOT/shell/tmux.conf"
  [ -f "$conf" ] || conf="$HOME/.laserbeak/tmux.conf"
  [ -f "$conf" ] || conf=/dev/null

  # Імʼя з міткою і pid: кожна вкладка отримує власну сесію tmux.
  # Запит долітає окремим аргументом — tmux не проганяє його через
  # оболонку, тож пробіли й зірочки в тексті лишаються як є.
  tmux -f "$conf" new-session -s "lb-${label}-$$" -c "$PWD" \
    -e "CLAUDE_LABEL=$label" \
    "${cmd[@]}" "${args[@]}"
}

# Скільки памʼяті тримає процес разом з усіма нащадками, у МБ.
# Сам tmux важить копійки, вага — у claude всередині панелі.
__lb_tree_rss() {
  ps -eo pid=,ppid=,rss= | awk -v root="$1" '
    { pid[NR]=$1; ppid[NR]=$2; rss[NR]=$3; n=NR }
    END {
      want[root]=1
      for (k = 0; k < 8; k++)
        for (i = 1; i <= n; i++)
          if (want[ppid[i]]) want[pid[i]] = 1
      for (i = 1; i <= n; i++) if (want[pid[i]]) s += rss[i]
      printf "%.0f", s / 1024
    }'
}

# Відчеплених сесій тепер бути й не повинно — destroy-unattached у
# shell/tmux.conf прибирає їх сам. Команда лишається для решти: убити
# сесію, не закриваючи вкладку, і підмести те, що висить із часів, коли
# tmux ще так не вмів.
#
# Лише kill-session і лише сесії lb-*: kill-server закрив би разом усі
# сесії на машині (див. docs/decisions.md).
stop() {
  local _LB_LANG="$(__lb_lang)"

  if ! command -v tmux >/dev/null 2>&1; then
    print -u2 -- "$(__lb_t tmux.missing)"
    return 1
  fi

  local out
  if ! out="$(tmux ls -F '#{session_name}|#{session_attached}|#{pane_pid}' 2>/dev/null)" || [ -z "$out" ]; then
    print -- "$(__lb_t stop.none)"
    return 0
  fi

  local -a rows targets
  local row name attached pane
  rows=( ${(f)out} )

  case "$1" in
    # Убити всі відчеплені. Приєднані — це відкриті вкладки, до них
    # не торкаємось: людина за ними сидить.
    -a|--all)
      for row in "${rows[@]}"; do
        name="${row%%|*}"
        attached="${${row#*|}%%|*}"
        [[ "$name" == lb-* ]] || continue
        (( attached )) || targets+=( "$name" )
      done
      if (( ! ${#targets} )); then
        print -- "$(__lb_t stop.noDetached)"
        return 0
      fi
      ;;

    # Нічого не передали — просто показати.
    "")
      printf "%-18s %-12s %8s\n" "$(__lb_t stop.label)" "$(__lb_t stop.state)" "$(__lb_t stop.memory)"
      for row in "${rows[@]}"; do
        name="${row%%|*}"
        attached="${${row#*|}%%|*}"
        pane="${row##*|}"
        local label="$name"
        # lb-<мітка>-<pid> -> <мітка>
        [[ "$name" == lb-*-* ]] && { label="${name#lb-}"; label="${label%-*}"; }
        printf "%-18s %-12s %6s %s\n" "$label" \
          "$( (( attached )) && __lb_t stop.tab || __lb_t stop.background )" \
          "$(__lb_tree_rss "$pane")" "$(__lb_t stop.mb)"
      done
      print -- "\n$(__lb_t stop.hint)"
      return 0
      ;;

    # Мітка. Імʼя сесії — lb-<мітка>-<pid>, тож шукаємо за префіксом.
    *)
      for row in "${rows[@]}"; do
        name="${row%%|*}"
        [[ "$name" == "lb-$1-"* ]] && targets+=( "$name" )
      done
      if (( ! ${#targets} )); then
        print -u2 -- "$(__lb_t stop.notFound "$1")"
        return 1
      fi
      ;;
  esac

  for name in "${targets[@]}"; do
    if tmux kill-session -t "$name" 2>/dev/null; then
      print -- "$(__lb_t stop.killed "$name")"
    else
      print -u2 -- "$(__lb_t stop.failed "$name")"
    fi
  done
}
