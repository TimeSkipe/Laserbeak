// Вікно налаштувань. Нічого не вирішує — показує стан і дає забути
// привʼязку, якщо група вкладок дісталась іншій сесії.

const DAEMON = 'http://127.0.0.1:8787';
const msg = (key, ...args) => chrome.i18n.getMessage(key, args.map(String));

document.getElementById('id').textContent = chrome.runtime.id;

// Розмітка тримає лише ключі: HTML до chrome.i18n не дотягнеться сам.
for (const el of document.querySelectorAll('[data-i18n]')) {
  el.textContent = msg(el.dataset.i18n);
}

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

show();
