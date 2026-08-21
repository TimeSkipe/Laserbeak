// Вікно налаштувань. Нічого не вирішує — показує стан і дає забути
// привʼязку, якщо група вкладок дісталась іншій сесії.

const DAEMON = 'http://127.0.0.1:8787';

document.getElementById('id').textContent = chrome.runtime.id;

async function show() {
  const dot = document.getElementById('dot');
  const line = document.getElementById('daemon');

  let state = null;
  try {
    const res = await fetch(`${DAEMON}/state`);
    state = await res.json();
  } catch {
    dot.className = 'dot bad';
    line.innerHTML = 'демон не відповідає <span class="muted">— npm run restart</span>';
    return;
  }

  const can = (state.sessions || []).filter((s) => s.canInput).length;
  dot.className = 'dot ok';
  line.innerHTML = `демон на звʼязку <span class="muted">· сесій, куди можна писати: ${can}</span>`;

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
      title: group.title || 'група вкладок',
      session: session ? (session.displayName || session.label) : 'сесії вже немає',
      project: session?.project || '',
    });
  }

  if (!rows.length) {
    box.innerHTML = '<div class="row"><span class="grow muted">'
      + 'ще нічого не привʼязано — сесію виберуть при першому виділенні</span></div>';
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
      <button>Забути</button>
    `;
    el.querySelector('button').addEventListener('click', async () => {
      await chrome.storage.local.remove(row.key);
      show();
    });
    box.appendChild(el);
  }
}

show();
