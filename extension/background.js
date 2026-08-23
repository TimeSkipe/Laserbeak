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

// Мову бере сам браузер — із власних налаштувань, а не з системи.
// Тексти лежать в _locales/<мова>/messages.json.
const msg = (key, ...args) => chrome.i18n.getMessage(key, args.map(String));

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

// captureVisibleTab віддає весь видимий кадр у фізичних пікселях, а
// рамку користувач малював у CSS-пікселях. На Retina це рівно вдвічі —
// без множення на dpr виріжеться не те, що обвели.
async function crop(dataUrl, rect, dpr) {
  const bitmap = await createImageBitmap(await (await fetch(dataUrl)).blob());

  const sx = Math.max(0, Math.round(rect.x * dpr));
  const sy = Math.max(0, Math.round(rect.y * dpr));
  const sw = Math.min(bitmap.width - sx, Math.round(rect.width * dpr));
  const sh = Math.min(bitmap.height - sy, Math.round(rect.height * dpr));

  if (sw < 1 || sh < 1) throw new Error(msg('errEmptyRegion'));

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
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['overlay.js'] });
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

chrome.runtime.onInstalled.addListener(() => {
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

async function send(tab, { sid, comment }) {
  const { pending } = await chrome.storage.session.get('pending');
  if (!pending) throw new Error(msg('errLostShot'));

  const result = await daemon('/sessions/shot', {
    method: 'POST',
    body: JSON.stringify({ sid, comment, ...pending }),
  });

  await chrome.storage.session.remove('pending');
  await writeBinding(tab, sid);
  return result;
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  const tab = sender.tab;

  const run = async () => {
    if (msg.type === 'lb:sessions') return listSessions(tab);
    if (msg.type === 'lb:shoot') return shoot(tab, msg);
    if (msg.type === 'lb:send') return send(tab, msg);
    return { ok: false, error: msg('errUnknownMessage') };
  };

  run().then(reply, (err) => reply({ ok: false, error: err.message }));
  return true;   // відповідь буде асинхронна
});
