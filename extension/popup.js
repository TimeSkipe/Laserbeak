// Вікно налаштувань. Нічого не вирішує — показує стан, дає забути
// привʼязку, якщо група вкладок дісталась іншій сесії, і вибрати мову.

const DAEMON = 'http://127.0.0.1:8787';
let msg = LaserbeakI18n.bind(null);

document.getElementById('id').textContent = chrome.runtime.id;

const picker = document.getElementById('language');

// Мова міняється на льоту: це вікно перемальовується одразу, service
// worker підхоплює зміну сам (storage.onChanged), а оверлей — на
// наступному виділенні.
async function applyLanguage() {
  const { language = 'auto' } = await chrome.storage.local.get('language');
  msg = LaserbeakI18n.bind(await LaserbeakI18n.load(language).catch(() => null));
  picker.value = language;
  document.documentElement.lang = LaserbeakI18n.LANGUAGES.includes(language)
    ? language
    : chrome.i18n.getUILanguage();

  // Розмітка тримає лише ключі: HTML до перекладу не дотягнеться сам.
  for (const el of document.querySelectorAll('[data-i18n]')) {
    el.textContent = msg(el.dataset.i18n);
  }
}

picker.addEventListener('change', async () => {
  await chrome.storage.local.set({ language: picker.value });
  await applyLanguage();
  show();
});

async function show() {
  const dot = document.getElementById('dot');
  const line = document.getElementById('daemon');

  let state = null;
  try {
    const res = await fetch(`${DAEMON}/state`);
    state = await res.json();
  } catch {
    dot.className = 'dot bad';
    line.innerHTML = `${msg('daemonDown')} <span class="muted">— npm run restart</span>`;
    return;
  }

  const can = (state.sessions || []).filter((s) => s.canInput).length;
  dot.className = 'dot ok';
  line.innerHTML = `${msg('daemonUp')} <span class="muted">· ${msg('sessionsAvailable', can)}</span>`;

  await showBinds(state);
}

// Привʼязки лежать ключами group:<id>. Показуємо лише живі: група,
// яку закрили, більше нікого не цікавить.
async function showBinds(state) {
  const box = document.getElementById('binds');
  const store = await chrome.storage.local.get(null);
  const groups = await chrome.tabGroups.query({});

  const byId = new Map((state.sessions || []).map((s) => [s.sid, s]));
  const rows = [];

  for (const group of groups) {
    const sid = store[`group:${group.id}`];
    if (!sid) continue;

    const session = byId.get(sid);
    rows.push({
      key: `group:${group.id}`,
      title: group.title || msg('tabGroup'),
      session: session ? (session.displayName || session.label) : msg('sessionGone'),
      project: session?.project || '',
    });
  }

  if (!rows.length) {
    box.innerHTML = '<div class="row"><span class="grow muted">'
      + msg('noBindings') + '</span></div>';
    return;
  }

  box.innerHTML = '';
  for (const row of rows) {
    const el = document.createElement('div');
    el.className = 'row';
    el.innerHTML = `
      <span class="grow">
        <span class="name">${row.title}</span><br>
        <span class="muted">→ ${row.session}${row.project ? ` · ${row.project}` : ''}</span>
      </span>
      <button>${msg('forget')}</button>
    `;
    el.querySelector('button').addEventListener('click', async () => {
      await chrome.storage.local.remove(row.key);
      show();
    });
    box.appendChild(el);
  }
}

applyLanguage().then(show);
