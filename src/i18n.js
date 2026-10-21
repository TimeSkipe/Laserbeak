'use strict';

// Тексти, які бачить користувач.
//
// Тут лише те, що справді доходить до людини: банери, історія подій,
// помилки, які повертає API, і текст, що йде в сесію зі скріншотом. Логи
// не перекладаємо навмисно — їх читає той, хто відкрив daemon.log, і
// шукати в них «сесію не знайдено» трьома мовами було б гірше, ніж однією.
//
// Чому переклад тут, а не в програмах: банер складає саме Laserbeak, і
// в запасному шляху через terminal-notifier ніякої програми взагалі
// немає. Клієнти нічого не обчислюють — правило те саме, що для решти.
//
// Мова одна на все. Програма на маку й розширення браузера беруть її
// звідси ж (поле `language` у /state), тож вибрана під час установки
// чеська — це чеська всюди, а не лише в банерах.
//
// Задають її двома способами, від сильнішого до слабшого:
// config.language (установка або вікно налаштувань) і «як у системі»
// (AppleLocale, потім $LANG). LASERBEAK_LANG перекриває обидва — але
// лише для разового запуску руками: у LaunchAgent його немає навмисно,
// інакше перемикач у програмі нічого б не міняв.

const { execFileSync } = require('child_process');
const config = require('./config');

const DEFAULT = 'en';

const STRINGS = {
  uk: {
    'notify.done': 'Закінчила роботу',
    'notify.permission': 'Потрібен дозвіл',
    'notify.idle': 'Чекає на твій ввід',

    'notify.update': 'Нова версія Laserbeak',
    'notify.updateCount': 'Нових змін на GitHub: {count}',
    'notify.updateSome': 'На GitHub є нові зміни',

    'history.waiting': 'чекає на ввід',
    'history.gone': 'сесія зникла (термінал закрито)',

    'shot.one': 'Подивись скріншот: {file}',
    'shot.many': 'Подивись скріншоти по черзі, це одна послідовність',
    'shot.marksOne': 'позначки кольором на знімку мої, на сторінці їх немає.',
    'shot.marksMany': 'позначки кольором на знімках мої, на сторінках їх немає.',
    'shot.element': 'елемент {selector}',
    'shot.text': 'текст «{text}»',
    'shot.where': 'це {where}.',
    'shot.region': 'Зона {size}.',

    'update.noGit': 'ця копія не з git — оновлень не відстежити',
    'update.notGitHub': 'origin веде не на GitHub — оновлень не відстежити',
    'update.network': 'GitHub не відповів: {reason}',
    'update.rateLimited': 'GitHub тимчасово обмежив запити — спробую пізніше',

    'history.done': 'Готово за {duration}',
    'history.doneNoTime': 'Готово',
    'history.opened': 'сесія відкрита',
    'history.closed': 'сесія закрита',
    'history.forgotten': 'прибрано вручну',

    'dur.seconds': '{s}с',
    'dur.minutes': '{m}хв {s}с',
    'dur.hours': '{h}год {m}хв',

    'err.noSession': 'сесії немає',
    'err.noSessionInArchive': 'сесії немає в архіві',
    'err.noProject': 'проєкт не знайдено',
    'err.noWayIn': 'сесію запущено без посередника — перезапусти її командою start',
    'err.badOrigin': 'цьому джерелу сюди не можна',
    'err.needSidText': 'потрібні sid і text',
    'err.needSidImage': 'потрібні sid і image',
    'err.tooManyShots': 'забагато знімків в одній послідовності — не більше {max}',
    'err.badCommand': 'невідома команда або значення',
    'err.notInCodex': 'у сесії Codex цього немає — там режими й модель влаштовані інакше',
    'err.badJson': 'тіло запиту — не JSON',
    'err.missing': 'бракує поля {field}',
    'err.notFound': 'такого маршруту немає',
    'err.onlyLocal': 'це можна лише з цього компʼютера',
    'err.badSetting': 'невідоме налаштування або значення: {key}',
    'err.configBroken': 'config.json пошкоджений — виправ його, і зміни можна буде зберегти',
    'err.unknownMode': 'невідомий режим: {mode}',
    'err.shotNotDataUrl': 'картинка має прийти як data URL із base64',
    'err.shotType': 'незрозумілий тип картинки: {type}',
    'err.shotEmpty': 'порожня картинка',
    'err.noTmux': 'tmux не встановлено',
    'err.notInTmux': 'сесія працює не в tmux',
    'err.paneGone': 'панель tmux уже закрита',
    'err.noClaude': 'не знайшов claude — перевір, чи він у PATH',
    'err.noProjectDir': 'немає такої теки проєкту',
    'err.notHosted': 'сесію запустив не Laserbeak',
    'err.sessionEnded': 'сесія вже завершилась',
    'err.tmuxFailed': 'tmux не прийняв ввід — подробиці в ~/.laserbeak/errors.log',
    'err.internal': 'внутрішня помилка демона — подробиці в ~/.laserbeak/errors.log',
    'act.edit': 'редагує {target}',
    'act.write': 'пише {target}',
    'act.read': 'читає {target}',
    'act.bash': 'виконує: {target}',
    'act.bashBare': 'виконує команду',
    'act.search': 'шукає «{target}»',
    'act.web': 'читає {target}',
    'act.websearch': 'шукає в мережі «{target}»',
    'act.agent': 'субагент: {target}',
    'act.agentBare': 'запустив субагента',
    'act.plan': 'оновлює план',
    'act.browser': 'керує браузером',
    'act.tool': 'інструмент {target}',
  },

  en: {
    'notify.done': 'Finished',
    'notify.permission': 'Permission needed',
    'notify.idle': 'Waiting for your input',

    'notify.update': 'New Laserbeak version',
    'notify.updateCount': 'New changes on GitHub: {count}',
    'notify.updateSome': 'There are new changes on GitHub',

    'history.waiting': 'waiting for input',
    'history.gone': 'session vanished (terminal closed)',

    'shot.one': 'Look at this screenshot: {file}',
    'shot.many': 'Look at the screenshots in order, they are one sequence',
    'shot.marksOne': 'the coloured marks on the shot are mine, they are not on the page.',
    'shot.marksMany': 'the coloured marks on the shots are mine, they are not on the pages.',
    'shot.element': 'element {selector}',
    'shot.text': 'text "{text}"',
    'shot.where': 'this is {where}.',
    'shot.region': 'Region {size}.',

    'update.noGit': 'this copy is not a git checkout — updates cannot be tracked',
    'update.notGitHub': 'origin does not point to GitHub — updates cannot be tracked',
    'update.network': 'GitHub did not answer: {reason}',
    'update.rateLimited': 'GitHub is rate-limiting requests — will try again later',

    'history.done': 'Done in {duration}',
    'history.doneNoTime': 'Done',
    'history.opened': 'session opened',
    'history.closed': 'session closed',
    'history.forgotten': 'removed by hand',

    'dur.seconds': '{s}s',
    'dur.minutes': '{m}m {s}s',
    'dur.hours': '{h}h {m}m',

    'err.noSession': 'no such session',
    'err.noSessionInArchive': 'no such session in the archive',
    'err.noProject': 'project not found',
    'err.noWayIn': 'this session was started without a go-between — restart it with the start command',
    'err.badOrigin': 'this origin is not allowed here',
    'err.needSidText': 'sid and text are required',
    'err.needSidImage': 'sid and image are required',
    'err.tooManyShots': 'too many shots in one sequence — {max} at most',
    'err.badCommand': 'unknown command or value',
    'err.notInCodex': 'not available in a Codex session — modes and models work differently there',
    'err.badJson': 'the request body is not JSON',
    'err.missing': 'missing field {field}',
    'err.notFound': 'no such route',
    'err.onlyLocal': 'only allowed from this computer',
    'err.badSetting': 'unknown setting or value: {key}',
    'err.configBroken': 'config.json is broken — fix it and changes can be saved again',
    'err.unknownMode': 'unknown mode: {mode}',
    'err.shotNotDataUrl': 'the image must arrive as a base64 data URL',
    'err.shotType': 'unknown image type: {type}',
    'err.shotEmpty': 'the image is empty',
    'err.noTmux': 'tmux is not installed',
    'err.notInTmux': 'this session is not running in tmux',
    'err.paneGone': 'the tmux pane is already closed',
    'err.noClaude': 'claude not found — check that it is on PATH',
    'err.noProjectDir': 'no such project folder',
    'err.notHosted': 'this session was not started by Laserbeak',
    'err.sessionEnded': 'the session has already ended',
    'err.tmuxFailed': 'tmux did not accept the input — details in ~/.laserbeak/errors.log',
    'err.internal': 'internal daemon error — details in ~/.laserbeak/errors.log',
    'act.edit': 'editing {target}',
    'act.write': 'writing {target}',
    'act.read': 'reading {target}',
    'act.bash': 'running: {target}',
    'act.bashBare': 'running a command',
    'act.search': 'searching for “{target}”',
    'act.web': 'reading {target}',
    'act.websearch': 'searching the web for “{target}”',
    'act.agent': 'subagent: {target}',
    'act.agentBare': 'started a subagent',
    'act.plan': 'updating the plan',
    'act.browser': 'driving the browser',
    'act.tool': 'tool {target}',
  },

  cs: {
    'notify.done': 'Hotovo',
    'notify.permission': 'Vyžaduje svolení',
    'notify.idle': 'Čeká na tvůj vstup',

    'notify.update': 'Nová verze Laserbeak',
    'notify.updateCount': 'Nových změn na GitHubu: {count}',
    'notify.updateSome': 'Na GitHubu jsou nové změny',

    'history.waiting': 'čeká na vstup',
    'history.gone': 'relace zmizela (terminál zavřen)',

    'shot.one': 'Podívej se na snímek obrazovky: {file}',
    'shot.many': 'Podívej se na snímky postupně, tvoří jednu sekvenci',
    'shot.marksOne': 'barevné značky na snímku jsou moje, na stránce nejsou.',
    'shot.marksMany': 'barevné značky na snímcích jsou moje, na stránkách nejsou.',
    'shot.element': 'prvek {selector}',
    'shot.text': 'text „{text}“',
    'shot.where': 'je to {where}.',
    'shot.region': 'Oblast {size}.',

    'update.noGit': 'tato kopie není z gitu — aktualizace nelze sledovat',
    'update.notGitHub': 'origin nevede na GitHub — aktualizace nelze sledovat',
    'update.network': 'GitHub neodpověděl: {reason}',
    'update.rateLimited': 'GitHub dočasně omezil požadavky — zkusím to později',

    'history.done': 'Hotovo za {duration}',
    'history.doneNoTime': 'Hotovo',
    'history.opened': 'relace otevřena',
    'history.closed': 'relace uzavřena',
    'history.forgotten': 'odstraněno ručně',

    'dur.seconds': '{s} s',
    'dur.minutes': '{m} min {s} s',
    'dur.hours': '{h} h {m} min',

    'err.noSession': 'relace neexistuje',
    'err.noSessionInArchive': 'relace není v archivu',
    'err.noProject': 'projekt nenalezen',
    'err.noWayIn': 'relace byla spuštěna bez prostředníka — restartuj ji příkazem start',
    'err.badOrigin': 'tento zdroj sem nesmí',
    'err.needSidText': 'je potřeba sid a text',
    'err.needSidImage': 'je potřeba sid a image',
    'err.tooManyShots': 'příliš mnoho snímků v jedné sekvenci — nejvýš {max}',
    'err.badCommand': 'neznámý příkaz nebo hodnota',
    'err.notInCodex': 'v relaci Codex to není — režimy a modely tam fungují jinak',
    'err.badJson': 'tělo požadavku není JSON',
    'err.missing': 'chybí pole {field}',
    'err.notFound': 'taková cesta neexistuje',
    'err.onlyLocal': 'povoleno jen z tohoto počítače',
    'err.badSetting': 'neznámé nastavení nebo hodnota: {key}',
    'err.configBroken': 'config.json je poškozený — oprav ho a změny půjde zase uložit',
    'err.unknownMode': 'neznámý režim: {mode}',
    'err.shotNotDataUrl': 'obrázek musí přijít jako data URL v base64',
    'err.shotType': 'neznámý typ obrázku: {type}',
    'err.shotEmpty': 'prázdný obrázek',
    'err.noTmux': 'tmux není nainstalovaný',
    'err.notInTmux': 'relace neběží v tmuxu',
    'err.paneGone': 'panel tmuxu už je zavřený',
    'err.noClaude': 'claude nenalezen — zkontroluj, že je v PATH',
    'err.noProjectDir': 'taková složka projektu neexistuje',
    'err.notHosted': 'relaci nespustil Laserbeak',
    'err.sessionEnded': 'relace už skončila',
    'err.tmuxFailed': 'tmux vstup nepřijal — podrobnosti v ~/.laserbeak/errors.log',
    'err.internal': 'vnitřní chyba démona — podrobnosti v ~/.laserbeak/errors.log',
    'act.edit': 'upravuje {target}',
    'act.write': 'píše {target}',
    'act.read': 'čte {target}',
    'act.bash': 'spouští: {target}',
    'act.bashBare': 'spouští příkaz',
    'act.search': 'hledá „{target}“',
    'act.web': 'čte {target}',
    'act.websearch': 'hledá na webu „{target}“',
    'act.agent': 'subagent: {target}',
    'act.agentBare': 'spustil subagenta',
    'act.plan': 'aktualizuje plán',
    'act.browser': 'ovládá prohlížeč',
    'act.tool': 'nástroj {target}',
  },

  ru: {
    'notify.done': 'Закончила работу',
    'notify.permission': 'Нужно разрешение',
    'notify.idle': 'Ждёт твоего ввода',
    'notify.update': 'Новая версия Laserbeak',
    'notify.updateCount': 'Новых изменений на GitHub: {count}',
    'notify.updateSome': 'На GitHub есть новые изменения',

    'history.waiting': 'ждёт ввода',
    'history.gone': 'сессия исчезла (терминал закрыт)',

    'shot.one': 'Посмотри скриншот: {file}',
    'shot.many': 'Посмотри скриншоты по очереди, это одна последовательность',
    'shot.marksOne': 'цветные пометки на снимке мои, на странице их нет.',
    'shot.marksMany': 'цветные пометки на снимках мои, на страницах их нет.',
    'shot.element': 'элемент {selector}',
    'shot.text': 'текст «{text}»',
    'shot.where': 'это {where}.',
    'shot.region': 'Область {size}.',

    'update.noGit': 'эта копия не из git — обновления не отследить',
    'update.notGitHub': 'origin ведёт не на GitHub — обновления не отследить',
    'update.network': 'GitHub не ответил: {reason}',
    'update.rateLimited': 'GitHub временно ограничил запросы — попробую позже',

    'history.done': 'Готово за {duration}',
    'history.doneNoTime': 'Готово',
    'history.opened': 'сессия открыта',
    'history.closed': 'сессия закрыта',
    'history.forgotten': 'убрано вручную',

    'dur.seconds': '{s}с',
    'dur.minutes': '{m}мин {s}с',
    'dur.hours': '{h}ч {m}мин',

    'err.noSession': 'такой сессии нет',
    'err.noSessionInArchive': 'в архиве нет такой сессии',
    'err.noProject': 'проект не найден',
    'err.noWayIn': 'сессия запущена без посредника — перезапусти её командой start',
    'err.badOrigin': 'этому источнику сюда нельзя',
    'err.needSidText': 'нужны sid и text',
    'err.needSidImage': 'нужны sid и image',
    'err.tooManyShots': 'слишком много снимков в одной последовательности — не больше {max}',
    'err.badCommand': 'неизвестная команда или значение',
    'err.notInCodex': 'в сессии Codex этого нет — там режимы и модель устроены иначе',
    'err.badJson': 'тело запроса — не JSON',
    'err.missing': 'не хватает поля {field}',
    'err.notFound': 'такого маршрута нет',
    'err.onlyLocal': 'это можно только с этого компьютера',
    'err.badSetting': 'неизвестная настройка или значение: {key}',
    'err.configBroken': 'config.json повреждён — исправь его, и изменения снова можно будет сохранить',
    'err.unknownMode': 'неизвестный режим: {mode}',
    'err.shotNotDataUrl': 'картинка должна прийти как data URL в base64',
    'err.shotType': 'непонятный тип картинки: {type}',
    'err.shotEmpty': 'пустая картинка',
    'err.noTmux': 'tmux не установлен',
    'err.notInTmux': 'сессия работает не в tmux',
    'err.paneGone': 'панель tmux уже закрыта',
    'err.noClaude': 'не нашёл claude — проверь, есть ли он в PATH',
    'err.noProjectDir': 'нет такой папки проекта',
    'err.notHosted': 'сессию запустил не Laserbeak',
    'err.sessionEnded': 'сессия уже завершилась',
    'err.tmuxFailed': 'tmux не принял ввод — подробности в ~/.laserbeak/errors.log',
    'err.internal': 'внутренняя ошибка демона — подробности в ~/.laserbeak/errors.log',
    'act.edit': 'редактирует {target}',
    'act.write': 'пишет {target}',
    'act.read': 'читает {target}',
    'act.bash': 'выполняет: {target}',
    'act.bashBare': 'выполняет команду',
    'act.search': 'ищет «{target}»',
    'act.web': 'читает {target}',
    'act.websearch': 'ищет в сети «{target}»',
    'act.agent': 'субагент: {target}',
    'act.agentBare': 'запустил субагента',
    'act.plan': 'обновляет план',
    'act.browser': 'управляет браузером',
    'act.tool': 'инструмент {target}',
  },

  kk: {
    'notify.done': 'Жұмысын аяқтады',
    'notify.permission': 'Рұқсат керек',
    'notify.idle': 'Сенің енгізуіңді күтіп тұр',
    'notify.update': 'Laserbeak: жаңа нұсқа',
    'notify.updateCount': 'GitHub-та жаңа өзгерістер: {count}',
    'notify.updateSome': 'GitHub-та жаңа өзгерістер бар',

    'history.waiting': 'енгізуді күтуде',
    'history.gone': 'сессия жоғалды (терминал жабылды)',

    'shot.one': 'Скриншотты қара: {file}',
    'shot.many': 'Скриншоттарды ретімен қара, бұл бір тізбек',
    'shot.marksOne': 'скриншоттағы түсті белгілер менікі, бетте олар жоқ.',
    'shot.marksMany': 'скриншоттардағы түсті белгілер менікі, беттерде олар жоқ.',
    'shot.element': '{selector} элементі',
    'shot.text': '«{text}» мәтіні',
    'shot.where': 'бұл — {where}.',
    'shot.region': 'Аймақ: {size}.',

    'update.noGit': 'бұл көшірме git-тен емес — жаңартуларды бақылау мүмкін емес',
    'update.notGitHub': 'origin GitHub-та емес — жаңартуларды бақылау мүмкін емес',
    'update.network': 'GitHub жауап бермеді: {reason}',
    'update.rateLimited': 'GitHub сұраныстарды уақытша шектеді — кейінірек қайталап көремін',

    'history.done': '{duration} ішінде дайын',
    'history.doneNoTime': 'Дайын',
    'history.opened': 'сессия ашылды',
    'history.closed': 'сессия жабылды',
    'history.forgotten': 'қолмен алынып тасталды',

    'dur.seconds': '{s}с',
    'dur.minutes': '{m}мин {s}с',
    'dur.hours': '{h}сағ {m}мин',

    'err.noSession': 'мұндай сессия жоқ',
    'err.noSessionInArchive': 'архивте мұндай сессия жоқ',
    'err.noProject': 'жоба табылмады',
    'err.noWayIn': 'сессия делдалсыз іске қосылған — оны start командасымен қайта іске қос',
    'err.badOrigin': 'бұл дереккөзге мұнда кіруге рұқсат жоқ',
    'err.needSidText': 'sid және text керек',
    'err.needSidImage': 'sid және image керек',
    'err.tooManyShots': 'бір тізбекте скриншот тым көп — ең көбі {max}',
    'err.badCommand': 'белгісіз команда немесе мән',
    'err.notInCodex': 'Codex сессиясында мұндай жоқ — онда режимдер мен модель басқаша жұмыс істейді',
    'err.badJson': 'сұраныс денесі JSON емес',
    'err.missing': '{field} өрісі жоқ',
    'err.notFound': 'мұндай маршрут жоқ',
    'err.onlyLocal': 'мұны тек осы компьютерден жасауға болады',
    'err.badSetting': 'белгісіз баптау немесе мән: {key}',
    'err.configBroken': 'config.json бүлінген — оны түзет, сонда өзгерістерді қайта сақтауға болады',
    'err.unknownMode': 'белгісіз режим: {mode}',
    'err.shotNotDataUrl': 'сурет base64 түріндегі data URL болып келуі керек',
    'err.shotType': 'суреттің белгісіз түрі: {type}',
    'err.shotEmpty': 'сурет бос',
    'err.noTmux': 'tmux орнатылмаған',
    'err.notInTmux': 'сессия tmux ішінде жұмыс істемейді',
    'err.paneGone': 'tmux панелі әлдеқашан жабылған',
    'err.noClaude': 'claude табылмады — оның PATH ішінде бар-жоғын тексер',
    'err.noProjectDir': 'мұндай жоба қалтасы жоқ',
    'err.notHosted': 'сессияны Laserbeak іске қоспаған',
    'err.sessionEnded': 'сессия әлдеқашан аяқталған',
    'err.tmuxFailed': 'tmux енгізуді қабылдамады — толығы ~/.laserbeak/errors.log файлында',
    'err.internal': 'демонның ішкі қатесі — толығы ~/.laserbeak/errors.log файлында',
    'act.edit': '{target} өңдеп жатыр',
    'act.write': '{target} жазып жатыр',
    'act.read': '{target} оқып жатыр',
    'act.bash': 'орындап жатыр: {target}',
    'act.bashBare': 'команда орындап жатыр',
    'act.search': '«{target}» іздеп жатыр',
    'act.web': '{target} оқып жатыр',
    'act.websearch': 'желіден «{target}» іздеп жатыр',
    'act.agent': 'субагент: {target}',
    'act.agentBare': 'субагент іске қосты',
    'act.plan': 'жоспарды жаңартып жатыр',
    'act.browser': 'браузерді басқарып жатыр',
    'act.tool': '{target} құралы',
  },
};

// Мову системи питаємо один раз: `defaults` коштує помітно дорожче за
// читання змінної, а посеред роботи вона не змінюється.
//
// «Як у системі» — це перша з мов інтерфейсу macOS (AppleLanguages), яку
// ми вміємо, а не регіон (AppleLocale): англійський інтерфейс із чеським
// форматом дат — це англійська. Так само мову вибирає і macOS для вікна
// програми, тож «auto» дає однакове скрізь. Жодної нашої в списку —
// англійська; програма тоді ставить собі англійську теж (Language.swift).
let systemLanguage = null;

function readDefaults(key) {
  try {
    return execFileSync('/usr/bin/defaults', ['read', '-g', key], {
      stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8', timeout: 2000,
    });
  } catch {
    return '';
  }
}

function detectSystem() {
  if (systemLanguage) return systemLanguage;

  // Вивід — список у дужках: ( "cs-CZ", "en-US" ).
  const preferred = [...readDefaults('AppleLanguages').matchAll(/"?([a-z]{2})[-_A-Za-z]*"?\s*[,)]/g)]
    .map((m) => m[1].toLowerCase());

  systemLanguage = preferred.find((code) => STRINGS[code])
    || [readDefaults('AppleLocale').trim(), process.env.LANG || '']
      .map((v) => v.slice(0, 2).toLowerCase())
      .find((code) => STRINGS[code])
    || DEFAULT;

  return systemLanguage;
}

// Порядок такий:
//
//   LASERBEAK_LANG   разовий запуск чи налагодження — сильніший за все
//   config.language  те, що вибрали під час установки або в програмі
//   "auto"           як у системі
//
// Змінна оточення попереду навмисно: перевірити чужу мову має бути
// можна одним запуском, не чіпаючи конфіг. Через це її й немає в
// LaunchAgent — там вона перекрила б вибір у програмі назавжди.
function current() {
  const fromEnv = String(process.env.LASERBEAK_LANG || '').toLowerCase();
  if (STRINGS[fromEnv]) return fromEnv;

  const wanted = config.get().language || 'auto';
  if (wanted === 'auto') return detectSystem();
  return STRINGS[wanted] ? wanted : DEFAULT;
}

/**
 * Переклад із підстановкою: t('history.done', { duration: '1хв 4с' }).
 *
 * Невідомий ключ повертається як є — краще побачити 'notify.oops' у
 * банері, ніж порожній рядок, який нічого не пояснює.
 */
function fill(template, params) {
  return template.replace(/\{(\w+)\}/g, (whole, name) => (
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole
  ));
}

function t(key, params = {}) {
  const lang = current();
  return fill(STRINGS[lang]?.[key] ?? STRINGS[DEFAULT]?.[key] ?? key, params);
}

// Той самий текст, але для лога — завжди українською, хоч би яку мову
// вибрала людина. Логи навмисно однією мовою (docs/decisions.md).
function tLog(key, params = {}) {
  return fill(STRINGS.uk?.[key] ?? key, params);
}

/**
 * Своя помилка: текст для людини вибраною мовою, для лога — українською.
 * Позначка `said` відрізняє її від чужих (ENOSPC, EPIPE): ті людині не
 * показуємо як є, бо вони сирі й англійською.
 */
function said(key, params = {}) {
  return Object.assign(new Error(t(key, params)), { said: true, logText: tLog(key, params) });
}

module.exports = { t, tLog, said, current, LANGUAGES: Object.keys(STRINGS) };
