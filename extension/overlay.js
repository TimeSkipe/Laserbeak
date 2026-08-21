// Виділення зони на сторінці.
//
// Живе в Shadow DOM: сторінка не має жодного стилю, який міг би сюди
// дотягнутись, а ми не залишаємо по собі нічого в її CSS. Інакше на
// кожному другому сайті рамка їхала б через якийсь глобальний
// `* { box-sizing }` чи `div { position: static !important }`.
//
// Про демон і сесії тут не знають нічого: оверлей питає service worker
// і показує, що той відповів.

(() => {
  if (window.__laserbeakOverlay) {
    window.__laserbeakOverlay.begin();
    return;
  }

  const msg = (key, ...args) => chrome.i18n.getMessage(key, args.map(String));

  const STYLES = `
    :host { all: initial; }
    .veil {
      position: fixed; inset: 0; z-index: 2147483646;
      cursor: crosshair; background: rgba(10, 12, 16, 0.42);
    }
    .hole {
      position: fixed; z-index: 2147483647; pointer-events: none;
      border: 1.5px solid #ff8a3d;
      box-shadow: 0 0 0 100vmax rgba(10, 12, 16, 0.42);
      border-radius: 2px;
    }
    .hint {
      position: fixed; left: 50%; top: 24px; transform: translateX(-50%);
      z-index: 2147483647; pointer-events: none;
      font: 500 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: #f2f4f8; background: rgba(20, 23, 30, 0.92);
      padding: 8px 14px; border-radius: 8px;
      box-shadow: 0 4px 20px rgba(0, 0, 0, 0.35);
    }
    .card {
      position: fixed; z-index: 2147483647; width: 340px;
      font: 400 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: #f2f4f8; background: rgba(24, 27, 34, 0.98);
      border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 12px;
      box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45);
      overflow: hidden;
    }
    .card img { display: block; width: 100%; max-height: 150px; object-fit: cover;
                object-position: top; border-bottom: 1px solid rgba(255,255,255,0.08); }
    .to { display: flex; align-items: center; gap: 6px; padding: 8px 12px;
          border-bottom: 1px solid rgba(255,255,255,0.08); }
    .to select {
      flex: 1; font: inherit; color: #f2f4f8; background: transparent;
      border: 0; outline: 0; padding: 2px 0; cursor: pointer;
    }
    .to select option { color: #111; }
    .arrow { color: #ff8a3d; font-weight: 600; }
    textarea {
      display: block; width: 100%; box-sizing: border-box; min-height: 62px;
      font: inherit; color: #f2f4f8; background: transparent;
      border: 0; outline: 0; padding: 10px 12px; resize: none;
    }
    textarea::placeholder { color: rgba(242, 244, 248, 0.38); }
    .foot { display: flex; justify-content: space-between; align-items: center;
            padding: 7px 12px; background: rgba(255,255,255,0.03);
            font-size: 11.5px; color: rgba(242,244,248,0.5); }
    .err { color: #ff7b6b; padding: 0 12px 9px; font-size: 12px; }
    .toast {
      position: fixed; left: 50%; bottom: 32px; transform: translateX(-50%);
      z-index: 2147483647; pointer-events: none;
      font: 500 13px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
      color: #f2f4f8; background: rgba(20, 23, 30, 0.95);
      padding: 10px 16px; border-radius: 9px;
      box-shadow: 0 6px 24px rgba(0,0,0,0.4);
    }
  `;

  const host = document.createElement('div');
  host.style.cssText = 'all: initial; position: static;';
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = `<style>${STYLES}</style>`;

  let veil = null;
  let hole = null;
  let hint = null;
  let card = null;
  let start = null;

  const clear = () => {
    for (const el of [veil, hole, hint, card]) el?.remove();
    veil = hole = hint = card = null;
    start = null;
    document.removeEventListener('keydown', onKey, true);
  };

  const el = (tag, cls) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    root.appendChild(n);
    return n;
  };

  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); clear(); }
  }

  // ── Селектор елемента ─────────────────────────────────────────────
  //
  // Це половина цінності всієї витівки: картинка каже, що не так, а
  // селектор каже, де це в коді. Тому data-* атрибути тестів мають
  // перевагу — вони стабільні й грепаються найкраще.

  const unique = (sel) => {
    try { return document.querySelectorAll(sel).length === 1; } catch { return false; }
  };

  // Один рівень шляху. Класи з хешами (styled-components, CSS modules) в
  // коді не знайти, тому такі відкидаємо: краще голий tag, ніж хибний слід.
  function segment(node) {
    const attr = ['data-testid', 'data-test', 'data-cy', 'data-qa']
      .map((a) => (node.getAttribute?.(a) ? `[${a}="${node.getAttribute(a)}"]` : ''))
      .find(Boolean);
    if (attr) return attr;

    if (node.id && !/^\d|[:.\s]/.test(node.id)) return `#${CSS.escape(node.id)}`;

    const tag = node.tagName.toLowerCase();
    const classes = Array.from(node.classList || [])
      .filter((c) => c.length < 28 && !/[0-9a-f]{5,}|--|^css-/i.test(c))
      .slice(0, 2)
      .map((c) => CSS.escape(c));

    return classes.length ? `${tag}.${classes.join('.')}` : tag;
  }

  // Позиція серед сусідів того ж тегу. Останній аргумент, коли ні класи,
  // ні атрибути не розрізняють елемент.
  function nth(node) {
    const parent = node.parentElement;
    if (!parent) return '';
    const same = Array.from(parent.children).filter((c) => c.tagName === node.tagName);
    return same.length > 1 ? `:nth-of-type(${same.indexOf(node) + 1})` : '';
  }

  // Селектор — половина цінності всієї витівки: картинка каже, що не так,
  // а він каже, де це в коді. Тому кожен крок перевіряється на реальній
  // сторінці: шлях, який знаходить шістнадцять елементів, гірший за
  // чесний короткий — сесія піде ним не туди.
  //
  // Спершу пробуємо без позицій: `nav.main > a.logo` читабельніший за
  // `div:nth-of-type(3) > ul > li:nth-of-type(2)`. Якщо не розрізняє —
  // перескладаємо з позиціями.
  function path(node, withNth) {
    const parts = [];
    let cur = node;

    // До body включно: шлях без якоря вгорі — це «будь-де на сторінці»,
    // і жодні позиції його не звузять. `ul > li > a` знаходило 58
    // посилань саме тому, що починалось нізвідки.
    for (let depth = 0; cur && depth < 12; depth++) {
      if (cur === document.body) { parts.unshift('body'); break; }

      parts.unshift(segment(cur) + (withNth ? nth(cur) : ''));
      const sel = parts.join(' > ');
      if (unique(sel)) return sel;

      cur = cur.parentElement;
    }

    return parts.join(' > ');
  }

  function describe(node) {
    if (!node || node === document.body || node === document.documentElement) return '';

    const plain = path(node, false);
    if (unique(plain)) return plain;

    const exact = path(node, true);
    return unique(exact) ? exact : plain;
  }

  // ── Крок 1: рамка ─────────────────────────────────────────────────

  function begin() {
    clear();

    veil = el('div', 'veil');
    hint = el('div', 'hint');
    hint.textContent = msg('hintDrag');

    document.addEventListener('keydown', onKey, true);

    veil.addEventListener('mousedown', (e) => {
      e.preventDefault();
      start = { x: e.clientX, y: e.clientY };

      hole = el('div', 'hole');
      hint.remove();

      const move = (ev) => {
        const r = rectOf(start, { x: ev.clientX, y: ev.clientY });
        Object.assign(hole.style, {
          left: `${r.x}px`, top: `${r.y}px`,
          width: `${r.width}px`, height: `${r.height}px`,
        });
      };

      const up = (ev) => {
        document.removeEventListener('mousemove', move, true);
        document.removeEventListener('mouseup', up, true);

        const r = rectOf(start, { x: ev.clientX, y: ev.clientY });
        if (r.width < 8 || r.height < 8) { clear(); return; }
        shoot(r);
      };

      document.addEventListener('mousemove', move, true);
      document.addEventListener('mouseup', up, true);
    }, true);
  }

  const rectOf = (a, b) => ({
    x: Math.min(a.x, b.x), y: Math.min(a.y, b.y),
    width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y),
  });

  // ── Крок 2: знімок ────────────────────────────────────────────────

  async function shoot(rect) {
    // Ховаємось до знімка: інакше в кадр потрапить власна рамка й
    // затемнення. Елемент під зоною теж шукаємо вже без себе.
    veil.style.display = 'none';
    hole.style.display = 'none';

    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    const target = document.elementFromPoint(cx, cy);

    const answer = await chrome.runtime.sendMessage({
      type: 'lb:shoot',
      rect,
      dpr: window.devicePixelRatio || 1,
      url: location.href,
      selector: describe(target),
      text: (target?.innerText || '').trim().slice(0, 80),
    });

    if (!answer?.ok) { fail(answer?.error || msg('errCapture')); return; }

    hole.style.display = '';
    ask(rect, answer);
  }

  // ── Крок 3: що з цим зробити ──────────────────────────────────────

  async function ask(rect, shot) {
    card = el('div', 'card');

    // Картку тримаємо у видимій частині: зона могла бути внизу екрана.
    const top = Math.min(rect.y + rect.height + 10, window.innerHeight - 300);
    const left = Math.min(Math.max(8, rect.x), window.innerWidth - 348);
    card.style.top = `${Math.max(8, top)}px`;
    card.style.left = `${left}px`;

    card.innerHTML = `
      <img src="${shot.preview}" alt="">
      <div class="to"><span class="arrow">→</span><select></select></div>
      <textarea placeholder="${msg('commentPlaceholder')}" rows="2"></textarea>
      <div class="foot"><span>${shot.size}</span><span>${msg('footHint')}</span></div>
    `;

    const select = card.querySelector('select');
    const area = card.querySelector('textarea');
    area.focus();

    const { sessions, bound } = await chrome.runtime.sendMessage({ type: 'lb:sessions' })
      .catch(() => ({ sessions: [], bound: '' }));

    if (!sessions?.length) {
      select.innerHTML = `<option>${msg('noSessions')}</option>`;
      select.disabled = true;
    } else {
      select.innerHTML = sessions
        .map((s) => `<option value="${s.sid}">${s.name}${s.project ? ` · ${s.project}` : ''}</option>`)
        .join('');
      if (bound && sessions.some((s) => s.sid === bound)) select.value = bound;
    }

    area.addEventListener('keydown', async (e) => {
      // Shift+Enter лишаємо сторінці: коментар буває на два речення.
      if (e.key !== 'Enter' || e.shiftKey) return;
      e.preventDefault();
      if (select.disabled) return;

      area.disabled = true;
      const res = await chrome.runtime.sendMessage({
        type: 'lb:send',
        sid: select.value,
        comment: area.value,
      }).catch((err) => ({ ok: false, error: err.message }));

      if (!res?.ok) { area.disabled = false; fail(res?.error || msg('errSend'), card); return; }

      const name = select.selectedOptions[0].textContent.split(' · ')[0];
      clear();
      toast(msg('sentTo', name));
    });
  }

  function fail(message, into) {
    if (into) {
      let box = into.querySelector('.err');
      if (!box) {
        box = document.createElement('div');
        box.className = 'err';
        into.appendChild(box);
      }
      box.textContent = message;
      return;
    }
    clear();
    toast(message);
  }

  function toast(message) {
    const t = el('div', 'toast');
    t.textContent = message;
    setTimeout(() => t.remove(), 2200);
  }

  document.documentElement.appendChild(host);
  window.__laserbeakOverlay = { begin };

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type === 'lb:begin') begin();
  });
})();
