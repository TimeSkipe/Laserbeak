// Service worker: усе, що говорить із демоном і з Chrome.
//
// Оверлей на сторінці нічого не знає ні про демон, ні про сесії — він
// лише малює рамку й питає. Так само, як програми на маку й телефоні:
// логіка в демоні, клієнт показує.
//
// Service worker у MV3 засинає після ~30 секунд без подій, і зазвичай
// його доводиться будити alarm'ами. Тут не доводиться: між виділенням
// зони й натисканням Enter ідуть повідомлення, а вони й тримають його
// живим. Але пережити сон він однаково має, тому знімок лежить не в
// змінній, а в chrome.storage.session.

const DAEMON = 'http://127.0.0.1:8787';

importScripts('i18n.js');

// Тексти лежать в _locales/<мова>/messages.json. Мова — як у браузері
// (не в системі!) або та, що вибрана у вікні налаштувань.
let msg = LaserbeakI18n.bind(null);
let strings = null;

async function applyLanguage() {
  const { language = 'auto' } = await chrome.storage.local.get('language');
  strings = await LaserbeakI18n.load(language).catch(() => null);
  msg = LaserbeakI18n.bind(strings);

  // Те, що браузер уже показує сам: пункти меню й підказку на іконці.
  // Меню може ще не існувати (воркер прокинувся раніше за onInstalled) —
  // тоді помилку ковтаємо, onInstalled створить його вже з потрібним текстом.
  const quiet = () => void chrome.runtime.lastError;
  chrome.contextMenus.update('lb-capture', { title: msg('menuCapture') }, quiet);
  chrome.contextMenus.update('lb-settings', { title: msg('menuSettings') }, quiet);
  chrome.action.setTitle({ title: msg('actionTitle') });
}

// Воркер засинає й прокидається, тож мову читаємо щоразу на старті, а
// все, що говорить із людиною, чекає на неї.
const languageReady = applyLanguage()
  .catch((err) => console.warn('[Laserbeak] мова:', err.message));

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.language) applyLanguage();
});

// Скільки чекати, поки браузер перемалює сторінку без нашого оверлея.
// Знімок робиться відразу після того, як оверлей сховався, — без цієї
// паузи в кадр потрапляє власна рамка.
const REPAINT_MS = 60;

// Межа, за якою знімок тиснемо в JPEG. PNG для інтерфейсу кращий —
// різкі краї й текст без ореолів, — але велика зона в PNG легко дає
// мегабайти, а вони потім їдуть у base64 з надбавкою в третину.
const PNG_LIMIT = 1_400_000;

const MAX_SIDE = 1600;

async function daemon(path, options = {}) {
  const res = await fetch(DAEMON + path, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
  });
  if (!res.ok) {
    let message = `демон відповів ${res.status}`;
    try { message = (await res.json()).error || message; } catch { /* лишаємо код */ }
    throw new Error(message);
  }
  return res.json();
}

// ── Привʼязка вкладок до сесій ──────────────────────────────────────
//
// Claude in Chrome складає вкладки однієї розмови у власну групу
// (tabGroupId), тому «яка вкладка чия» — не здогад, а факт із API.
// Групу питаємо один раз, далі памʼятаємо.

async function bindingKey(tab) {
  // groupId = -1 означає, що вкладка не в групі: тоді памʼятати нічого,
  // беремо останню вибрану сесію.
  return tab.groupId && tab.groupId !== -1 ? `group:${tab.groupId}` : 'last';
}

// Скільки часу браузерний виклик вважається «щойно». Група вкладок
// створюється саме в мить, коли сесія бере браузер, тож вистачило б і
// кількох секунд — але демон дочитує транскрипт раз на дві секунди, а
// сесія могла відкрити вкладку не першою ж дією.
const RECENT_MS = 3 * 60_000;

/**
 * Кому належить нова група вкладок.
 *
 * Найнадійніший сигнал — хто щойно керував браузером: демон бачить
 * виклики mcp__claude-in-chrome__* у транскрипті, тож це не здогад.
 * Якщо такого сліду немає, годиться й «працює рівно одна сесія».
 */
async function guessSession() {
  let state;
  try {
    state = await daemon('/state');
  } catch {
    return '';
  }

  const usable = (state.sessions || []).filter((s) => s.canInput);

  const recent = usable
    .filter((s) => s.lastBrowserUse && Date.now() - s.lastBrowserUse < RECENT_MS)
    .sort((a, b) => b.lastBrowserUse - a.lastBrowserUse);
  if (recent.length) return recent[0].sid;

  const working = usable.filter((s) => s.status === 'working');
  return working.length === 1 ? working[0].sid : '';
}

async function readBinding(tab) {
  const key = await bindingKey(tab);
  const store = await chrome.storage.local.get([key, 'last']);
  if (store[key]) return store[key];

  // Групи ще немає в памʼяті — або її створили, поки розширення спало,
  // або воно взагалі стало пізніше. Пробуємо визначити самі.
  if (key !== 'last') {
    const guessed = await guessSession();
    if (guessed) {
      await chrome.storage.local.set({ [key]: guessed });
      return guessed;
    }
  }

  return store.last || '';
}

async function writeBinding(tab, sid) {
  const key = await bindingKey(tab);
  await chrome.storage.local.set({ [key]: sid, last: sid });
}

// Щойно Claude in Chrome заводить групу вкладок — привʼязуємо її мовчки,
// не чекаючи, поки користувач щось виділить.
//
// Перша спроба часто порожня: демон дочитує транскрипт раз на дві
// секунди, тож слід виклику ще не встиг долетіти. Тому друга спроба
// трохи згодом.
chrome.tabGroups.onCreated.addListener(async (group) => {
  const key = `group:${group.id}`;

  for (const delay of [0, 3000]) {
    if (delay) await new Promise((r) => setTimeout(r, delay));

    const store = await chrome.storage.local.get(key);
    if (store[key]) return;

    const sid = await guessSession();
    if (sid) {
      await chrome.storage.local.set({ [key]: sid });
      console.log('[Laserbeak] групу', group.id, '→ сесія', sid.slice(0, 8));
      return;
    }
  }
});

// ── Знімок ──────────────────────────────────────────────────────────

const bitmapOf = async (dataUrl) => createImageBitmap(await (await fetch(dataUrl)).blob());

// captureVisibleTab віддає весь видимий кадр у фізичних пікселях, а
// рамку користувач малював у CSS-пікселях. На Retina це рівно вдвічі —
// без множення на dpr виріжеться не те, що обвели.
async function crop(dataUrl, rect, dpr) {
  const bitmap = await bitmapOf(dataUrl);

  const sx = Math.max(0, Math.round(rect.x * dpr));
  const sy = Math.max(0, Math.round(rect.y * dpr));
  const sw = Math.min(bitmap.width - sx, Math.round(rect.width * dpr));
  const sh = Math.min(bitmap.height - sy, Math.round(rect.height * dpr));

  if (sw < 1 || sh < 1) throw new Error(msg('errEmptyRegion'));

  return pack(bitmap, sx, sy, sw, sh);
}

// Частина картинки → data URL, готовий їхати в демон. Через це
// проходить і свіжий знімок, і розмальований: межі розміру й ваги в
// обох однакові.
async function pack(bitmap, sx, sy, sw, sh) {
  // Дуже великі зони зменшуємо: дрібніший текст сесії однаково не
  // потрібен, а вага росте квадратично.
  const scale = Math.min(1, MAX_SIDE / Math.max(sw, sh));
  const dw = Math.round(sw * scale);
  const dh = Math.round(sh * scale);

  const canvas = new OffscreenCanvas(dw, dh);
  const ctx = canvas.getContext('2d');
  ctx.drawImage(bitmap, sx, sy, sw, sh, 0, 0, dw, dh);
  bitmap.close();

  let blob = await canvas.convertToBlob({ type: 'image/png' });
  if (blob.size > PNG_LIMIT) {
    blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.85 });
  }

  const buf = await blob.arrayBuffer();
  let binary = '';
  const bytes = new Uint8Array(buf);
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }

  return {
    dataUrl: `data:${blob.type};base64,${btoa(binary)}`,
    size: `${dw}×${dh}`,
    bytes: blob.size,
  };
}

// ── Запуск виділення ────────────────────────────────────────────────

async function startCapture(tab) {
  if (!tab?.id) return;

  // chrome:// і Web Store не пускають до себе нікого — сказати про це
  // нема куди, бо й оверлей туди не вставиш. Просто тихо виходимо.
  if (!/^https?:|^file:/.test(tab.url || '')) return;

  try {
    // Стилі не вставляємо: оверлей живе у Shadow DOM і несе їх у собі,
    // тож у CSS сторінки ми не лишаємо нічого.
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['i18n.js', 'overlay.js'] });
    await chrome.tabs.sendMessage(tab.id, { type: 'lb:begin' });
  } catch (err) {
    console.warn('[Laserbeak]', msg('errOpenOverlay') + ':', err.message);
  }
}

chrome.action.onClicked.addListener(startCapture);

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== 'capture') return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  startCapture(tab);
});

chrome.runtime.onInstalled.addListener(async () => {
  await languageReady;
  chrome.contextMenus.create({
    id: 'lb-capture',
    title: msg('menuCapture'),
    contexts: ['page', 'selection', 'image', 'link'],
  });
  chrome.contextMenus.create({
    id: 'lb-settings',
    title: msg('menuSettings'),
    contexts: ['action'],
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === 'lb-capture') startCapture(tab);
  if (info.menuItemId === 'lb-settings') {
    chrome.windows.create({ url: 'popup.html', type: 'popup', width: 420, height: 560 });
  }
});

// ── Розмова з оверлеєм ──────────────────────────────────────────────

async function listSessions(tab) {
  const state = await daemon('/state');

  // Показуємо лише те, куди справді можна писати: сесія без посередника
  // однаково відмовить, і краще не пропонувати її взагалі.
  const sessions = (state.sessions || [])
    .filter((s) => s.canInput)
    .map((s) => ({
      sid: s.sid,
      name: s.displayName || s.alias || s.label || s.sid.slice(0, 6),
      project: s.project || '',
      status: s.status || '',
      agent: s.agent || 'claude',
    }));

  // Та, що зараз працює, — найімовірніша адресатка.
  const rank = { working: 0, 'needs-input': 1, waiting: 2 };
  sessions.sort((a, b) => (rank[a.status] ?? 3) - (rank[b.status] ?? 3));

  return { sessions, bound: await readBinding(tab) };
}

async function shoot(tab, payload) {
  await new Promise((r) => setTimeout(r, REPAINT_MS));

  const full = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
  const shot = await crop(full, payload.rect, payload.dpr);

  await chrome.storage.session.set({
    pending: {
      image: shot.dataUrl,
      size: shot.size,
      url: payload.url,
      selector: payload.selector,
      text: payload.text,
    },
  });

  return { ok: true, preview: shot.dataUrl, size: shot.size, bytes: shot.bytes };
}

// Знімок із позначками користувача замість чистого. Чистий лишається
// поруч: стерли всі позначки — повертаємо його, а не перекодовуємо
// намальоване з нічим.
async function mark({ image }) {
  const { pending } = await chrome.storage.session.get('pending');
  if (!pending) throw new Error(msg('errLostShot'));

  const { clean = pending.image, ...rest } = pending;

  if (!image) {
    await chrome.storage.session.set({ pending: { ...rest, image: clean, marked: false } });
    return { ok: true, preview: clean };
  }

  const bitmap = await bitmapOf(image);
  const shot = await pack(bitmap, 0, 0, bitmap.width, bitmap.height);
  await chrome.storage.session.set({
    pending: { ...rest, image: shot.dataUrl, clean, marked: true },
  });

  return { ok: true, preview: shot.dataUrl, bytes: shot.bytes };
}

// ── Послідовність знімків ───────────────────────────────────────────
//
// «Спершу тиснеш тут — відкривається оце, а мало б інше». Кожен знімок
// зі своїм коментарем відкладається в чергу, а в сесію все летить одним
// запитом, по порядку.
//
// Черга лежить тут, а не в оверлеї: оверлей живе на сторінці й помирає
// разом із нею, а наступний знімок часто вже на іншій сторінці.

// Та сама межа, що й у демоні (MAX_SERIES у src/shots.js).
const MAX_SERIES = 8;

async function readSeries() {
  const { series = [] } = await chrome.storage.session.get('series');
  return series;
}

async function listSeries() {
  const series = await readSeries();
  return {
    ok: true,
    items: series.map((s) => ({ image: s.image, comment: s.comment || '' })),
    max: MAX_SERIES,
  };
}

// Поточний знімок разом із коментарем — у чергу, місце під наступний.
async function next({ comment }) {
  const { pending } = await chrome.storage.session.get('pending');
  if (!pending) throw new Error(msg('errLostShot'));

  // Відкладений знімок уже не правлять, тож чистий більше не потрібен.
  const { clean, ...shot } = pending;
  const series = await readSeries();

  // +2: той, що відкладаємо, і той, що буде знято слідом.
  if (series.length + 2 > MAX_SERIES) throw new Error(msg('errSeriesFull'));

  try {
    await chrome.storage.session.set({ series: [...series, { ...shot, comment }] });
  } catch {
    // storage.session тримає 10 МБ на все розширення, а великі зони
    // бувають по два. Краще сказати зараз, ніж загубити знімок.
    throw new Error(msg('errSeriesFull'));
  }
  await chrome.storage.session.remove('pending');

  return { ok: true, count: series.length + 1 };
}

async function drop({ index }) {
  const series = await readSeries();
  series.splice(index, 1);
  await chrome.storage.session.set({ series });
  return listSeries();
}

async function send(tab, { sid, comment }) {
  const { pending } = await chrome.storage.session.get('pending');
  if (!pending) throw new Error(msg('errLostShot'));

  // Чистий знімок лишається тут: демонові він не потрібен, а важить
  // стільки ж, скільки й основний.
  const { clean, ...shot } = pending;
  const current = { ...shot, comment };
  const series = await readSeries();

  // Один знімок їде полями самого тіла, як і досі; кілька — масивом.
  const body = series.length ? { sid, shots: [...series, current] } : { sid, ...current };

  const result = await daemon('/sessions/shot', {
    method: 'POST',
    body: JSON.stringify(body),
  });

  await chrome.storage.session.remove(['pending', 'series']);
  await writeBinding(tab, sid);
  return result;
}

// Параметр — не `msg`: так звуть функцію перекладу, і затінена вона
// падала б саме там, де мала пояснити помилку.
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  const tab = sender.tab;

  const run = async () => {
    await languageReady;
    if (message.type === 'lb:strings') return { ok: true, table: strings };
    if (message.type === 'lb:sessions') return listSessions(tab);
    if (message.type === 'lb:shoot') return shoot(tab, message);
    if (message.type === 'lb:mark') return mark(message);
    if (message.type === 'lb:series') return listSeries();
    if (message.type === 'lb:next') return next(message);
    if (message.type === 'lb:drop') return drop(message);
    if (message.type === 'lb:send') return send(tab, message);
    return { ok: false, error: msg('errUnknownMessage') };
  };

  run().then(reply, (err) => reply({ ok: false, error: err.message }));
  return true;   // відповідь буде асинхронна
});
