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

  // Тексти дає service worker: мову могли вибрати вручну, а _locales ми
  // сторінкам не відкриваємо. Питаємо на початку кожного виділення —
  // мову могли змінити, поки оверлей жив на сторінці.
  let msg = LaserbeakI18n.bind(null);
  const loadStrings = async () => {
    const res = await chrome.runtime.sendMessage({ type: 'lb:strings' }).catch(() => null);
    msg = LaserbeakI18n.bind(res?.table || null);
  };

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
      max-width: calc(100vw - 16px); max-height: calc(100vh - 16px);
      display: flex; flex-direction: column;
      font: 400 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: #f2f4f8; background: rgba(24, 27, 34, 0.98);
      border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 12px;
      box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45);
      overflow: hidden;
    }
    /* На низькому екрані поступається прев'ю, а не поле для тексту:
       без поля картка втрачає сенс, без великого прев'ю — ні. */
    .card > * { flex: none; }
    .card > .shot { flex: 0 1 auto; min-height: 48px; overflow: hidden; }
    .shot img { display: block; width: 100%; max-height: 150px; object-fit: cover;
                object-position: top; border-bottom: 1px solid rgba(255,255,255,0.08);
                cursor: zoom-in; }
    .seq { display: flex; align-items: center; gap: 8px; padding: 6px 12px;
           border-bottom: 1px solid rgba(255,255,255,0.08); }
    .thumbs { display: flex; align-items: center; gap: 6px; flex: 1; min-width: 0;
              overflow-x: auto; scrollbar-width: none; }
    .thumb { position: relative; flex: none; width: 38px; height: 26px; border-radius: 4px;
             overflow: hidden; background: #0b0d11;
             box-shadow: inset 0 0 0 1px rgba(255,255,255,0.16); }
    .thumb img { display: block; width: 100%; height: 100%; object-fit: cover; object-position: top; }
    .thumb .num { position: absolute; left: 2px; bottom: 2px; padding: 2px 3px; border-radius: 3px;
                  font: 600 9px/1 -apple-system, BlinkMacSystemFont, sans-serif;
                  color: #fff; background: rgba(0, 0, 0, 0.72); }
    .thumb .drop { position: absolute; inset: 0; display: none; place-items: center;
                   padding: 0; border: 0; cursor: pointer;
                   font: 600 15px/1 -apple-system, BlinkMacSystemFont, sans-serif;
                   color: #fff; background: rgba(10, 12, 16, 0.75); }
    .thumb:hover .drop { display: grid; }
    .now { flex: none; display: grid; place-items: center; width: 26px; height: 26px;
           border-radius: 4px; font: 600 11px/1 -apple-system, BlinkMacSystemFont, sans-serif;
           color: #ff8a3d; box-shadow: inset 0 0 0 1.5px #ff8a3d; }
    .next {
      flex: none; margin-left: auto; display: flex; align-items: center; gap: 4px;
      font: 500 12px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: #f2f4f8; background: rgba(255, 255, 255, 0.06);
      border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 999px;
      padding: 5px 10px 5px 7px; cursor: pointer;
    }
    .next:hover { color: #1a1206; background: #ff8a3d; border-color: transparent; }
    .next:disabled { opacity: 0.5; cursor: default; }
    .next[hidden] { display: none; }
    .next svg { width: 13px; height: 13px; }
    svg { fill: none; stroke: currentColor; stroke-width: 2;
          stroke-linecap: round; stroke-linejoin: round; }
    .shot { position: relative; }
    .pen {
      position: absolute; top: 8px; right: 8px;
      display: flex; align-items: center; gap: 5px;
      font: 500 12px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: #f2f4f8; background: rgba(20, 23, 30, 0.84);
      border: 1px solid rgba(255, 255, 255, 0.16); border-radius: 999px;
      padding: 5px 10px 5px 8px; cursor: pointer;
      box-shadow: 0 2px 10px rgba(0, 0, 0, 0.3);
    }
    .pen:hover { background: #ff8a3d; border-color: transparent; color: #1a1206; }
    .pen svg { width: 13px; height: 13px; }
    .studio {
      position: fixed; inset: 0; z-index: 2147483647;
      display: flex; flex-direction: column; align-items: center;
      justify-content: center; gap: 12px; padding: 16px; box-sizing: border-box;
      font: 400 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: #f2f4f8; background: rgba(10, 12, 16, 0.8);
    }
    .tools {
      display: flex; flex-wrap: wrap; justify-content: center; align-items: center;
      gap: 2px; padding: 6px; max-width: 100%; box-sizing: border-box;
      background: rgba(24, 27, 34, 0.98);
      border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 12px;
      box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45);
    }
    .tools .sep { width: 1px; height: 22px; margin: 0 5px; background: rgba(255, 255, 255, 0.12); }
    .tools button {
      display: grid; place-items: center; width: 32px; height: 32px; padding: 0;
      font: inherit; color: rgba(242, 244, 248, 0.75); background: transparent;
      border: 0; border-radius: 8px; cursor: pointer;
    }
    .tools button:hover { color: #f2f4f8; background: rgba(255, 255, 255, 0.08); }
    .tools button.on { color: #ff8a3d; background: rgba(255, 138, 61, 0.16); }
    .tools button:disabled { opacity: 0.3; cursor: default; background: transparent; }
    .tools button svg { width: 18px; height: 18px; }
    .tools .swatch { width: 28px; }
    .tools .swatch i {
      display: block; width: 16px; height: 16px; border-radius: 50%;
      box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.28);
    }
    .tools .swatch.on { background: transparent; }
    .tools .swatch.on i { box-shadow: 0 0 0 2px #181b22, 0 0 0 4px #f2f4f8; }
    .tools .text { width: auto; padding: 0 12px; font-weight: 500; color: #f2f4f8; }
    .tools .primary { color: #1a1206; background: #ff8a3d; margin-left: 4px; }
    .tools .primary:hover { color: #1a1206; background: #ff9d5c; }
    .studio canvas {
      display: block; max-width: 100%; cursor: crosshair; touch-action: none;
      border-radius: 3px;
      box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.14), 0 16px 48px rgba(0, 0, 0, 0.5);
    }
    .studio .note { font-size: 12px; color: rgba(242, 244, 248, 0.55); text-align: center; }
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

  // Позначки на знімку: чистий знімок, фігури поверх нього й відкритий
  // редактор. Інструмент і колір переживають і редактор, і сам знімок —
  // хто малює червоною стрілкою, той малюватиме нею й наступного разу.
  let base = null;
  let marks = [];
  let studio = null;
  let tool = 'pen';
  let color = '#ff3b30';

  // Знімки, відкладені кнопкою «Наступний». Сама черга живе в service
  // worker'і — тут лише її копія, щоб показати мініатюри й номер.
  let series = [];
  let seriesMax = 8;
  let seriesLoaded = Promise.resolve();

  const loadSeries = async () => {
    const res = await chrome.runtime.sendMessage({ type: 'lb:series' }).catch(() => null);
    series = res?.items || [];
    seriesMax = res?.max || seriesMax;
  };

  // Хто стежить за розміром картки, щоб тримати її на екрані.
  let unplace = null;

  const clear = () => {
    unplace?.();
    unplace = null;
    for (const el of [veil, hole, hint, card, studio?.el]) el?.remove();
    veil = hole = hint = card = studio = base = null;
    marks = [];
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
    if (studio) { studio.onKey(e); return; }
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); cancel(); }
  }

  // Скасувати поточний знімок. Відкладені лишаються в черзі: Esc посеред
  // послідовності найчастіше означає «піду на іншу сторінку по наступний».
  function cancel() {
    const queued = series.length;
    clear();
    if (queued) toast(msg('seriesKept', queued), 3500);
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

  async function begin() {
    await loadStrings();
    clear();

    veil = el('div', 'veil');
    hint = el('div', 'hint');
    hint.textContent = msg('hintDrag');

    // Посеред послідовності підказка каже, котрий це знімок і що Esc не
    // губить уже зняте.
    const own = hint;
    seriesLoaded = loadSeries().then(() => {
      if (series.length) own.textContent = msg('hintDragNext', series.length + 1);
    });

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
        if (r.width < 8 || r.height < 8) { cancel(); return; }
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
    await seriesLoaded;
    card = el('div', 'card');

    card.innerHTML = `
      <div class="shot">
        <img src="${shot.preview}" alt="">
        <button class="pen" title="${msg('markButtonTitle')}">${icon('pen')}<span>${msg('markButton')}</span></button>
      </div>
      <div class="seq">
        <div class="thumbs"></div>
        <button class="next" title="${msg('nextTitle')}">${icon('plus')}<span>${msg('nextButton')}</span></button>
      </div>
      <div class="to"><span class="arrow">→</span><select></select></div>
      <textarea rows="2"></textarea>
      <div class="foot"><span>${shot.size}</span><span class="keys"></span></div>
    `;

    const select = card.querySelector('select');
    const area = card.querySelector('textarea');
    const preview = card.querySelector('.shot img');
    const thumbs = card.querySelector('.thumbs');
    const nextButton = card.querySelector('.next');
    const keys = card.querySelector('.keys');

    // Попередні знімки послідовності — мініатюрами з номерами; поточний
    // — рамкою з наступним номером. Enter відправляє всі разом.
    const showSeries = () => {
      thumbs.replaceChildren(...series.map((s, i) => {
        const t = document.createElement('div');
        t.className = 'thumb';
        t.title = s.comment;
        t.innerHTML = `<img src="${s.image}" alt=""><span class="num">${i + 1}</span>`
          + `<button class="drop" title="${msg('seriesDrop')}" aria-label="${msg('seriesDrop')}">×</button>`;
        t.querySelector('.drop').addEventListener('click', async () => {
          const res = await chrome.runtime.sendMessage({ type: 'lb:drop', index: i }).catch(() => null);
          if (res?.ok) { series = res.items; showSeries(); }
          area.focus();
        });
        return t;
      }));

      if (series.length) {
        const now = document.createElement('span');
        now.className = 'now';
        now.textContent = series.length + 1;
        thumbs.append(now);
        thumbs.scrollLeft = thumbs.scrollWidth;
      }

      nextButton.hidden = series.length + 1 >= seriesMax;
      keys.textContent = series.length ? msg('footHintSeries', series.length + 1) : msg('footHint');
      area.placeholder = series.length ? msg('commentPlaceholderNext') : msg('commentPlaceholder');
    };
    showSeries();

    // Картка мусить бути цілком на екрані, інакше в поле не клікнеш. Під
    // зоною, якщо влазить; інакше над нею, щоб не закривати обведене;
    // інакше — притиснута до низу екрана.
    //
    // Висота міняється й після показу: прев'ю декодується не одразу
    // (поміряна до того картка вилазила за край на висоту картинки),
    // зʼявляються помилка чи мініатюри. Тож місце перераховуємо щоразу,
    // коли картка або вікно міняє розмір.
    const place = () => {
      const h = card.offsetHeight;
      const below = rect.y + rect.height + 10;
      const above = rect.y - h - 10;
      let top = window.innerHeight - h - 8;
      if (below + h <= window.innerHeight - 8) top = below;
      else if (above >= 8) top = above;
      card.style.top = `${Math.max(8, top)}px`;
      card.style.left = `${Math.max(8, Math.min(rect.x, window.innerWidth - card.offsetWidth - 8))}px`;
    };
    place();
    const watch = new ResizeObserver(place);
    watch.observe(card);
    window.addEventListener('resize', place);
    unplace = () => { watch.disconnect(); window.removeEventListener('resize', place); };
    area.focus();

    // Цей знімок — у чергу, а тут-таки рамка для наступного. Якщо
    // наступний на іншій сторінці, Esc: черга лишиться, ⌘⇧E продовжить.
    nextButton.addEventListener('click', async () => {
      nextButton.disabled = true;
      const res = await chrome.runtime.sendMessage({ type: 'lb:next', comment: area.value })
        .catch((err) => ({ ok: false, error: err.message }));
      if (!res?.ok) { nextButton.disabled = false; fail(res?.error || msg('errSeriesFull'), card); return; }
      begin();
    });

    // Малюємо завжди по чистому знімку: на картці після редактора вже
    // намальоване, а фігури лежать окремо й накладаються щоразу заново.
    base = new Image();
    base.src = shot.preview;
    const open = () => markUp(preview, area);
    preview.addEventListener('click', open);
    card.querySelector('.pen').addEventListener('click', open);

    const { sessions, bound } = await chrome.runtime.sendMessage({ type: 'lb:sessions' })
      .catch(() => ({ sessions: [], bound: '' }));

    if (!sessions?.length) {
      select.innerHTML = `<option>${msg('noSessions')}</option>`;
      select.disabled = true;
    } else {
      select.innerHTML = sessions
        // Codex позначаємо: дві сесії з однаковою назвою в одному проєкті
        // інакше не розрізнити, а скрін полетів би не тому агентові.
        .map((s) => `<option value="${s.sid}">${s.name}${s.project ? ` · ${s.project}` : ''}${s.agent === 'codex' ? ' · Codex' : ''}</option>`)
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

  // ── Позначки на знімку ────────────────────────────────────────────
  //
  // Словами не завжди скажеш, як має бути: «ця рамка ширша, а кнопка
  // отут». Тож поверх знімка можна намалювати — від руки, стрілкою,
  // колом чи прямокутником.
  //
  // Фігури лежать векторами в пікселях знімка, а не пікселями на
  // полотні: так працює «назад», а повторне відкриття показує чистий
  // знімок, і позначки на ньому можна далі правити.

  const TOOLS = [
    ['pen', 'toolPen'],
    ['arrow', 'toolArrow'],
    ['ellipse', 'toolEllipse'],
    ['rect', 'toolRect'],
  ];

  const COLORS = [
    ['#ff3b30', 'colorRed'],
    ['#ffcc00', 'colorYellow'],
    ['#34c759', 'colorGreen'],
    ['#0a84ff', 'colorBlue'],
    ['#111111', 'colorBlack'],
    ['#ffffff', 'colorWhite'],
  ];

  // Lucide, як і в програмах.
  const ICONS = {
    pen: '<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>',
    arrow: '<path d="M7 17 17 7"/><path d="M7 7h10v10"/>',
    ellipse: '<circle cx="12" cy="12" r="9"/>',
    rect: '<rect x="3" y="3" width="18" height="18" rx="2"/>',
    plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
    undo: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11"/>',
    clear: '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
  };
  const icon = (name) => `<svg viewBox="0 0 24 24">${ICONS[name]}</svg>`;

  // Товщина лінії на екрані, у CSS-пікселях. У пікселях знімка вона
  // інша — залежить від того, наскільки знімок збільшено.
  const LINE = 4;

  // У скільки разів найбільше збільшувати малу зону відносно того, як
  // вона виглядала на сторінці. Далі кожен піксель знімка стає
  // квадратиком, і точніше вже не намалюєш.
  const ZOOM_MAX = 8;

  // Та сама межа, що й у background.js: більше однаково зменшать дорогою.
  const MAX_SIDE = 1600;

  // Shift вирівнює: коло замість овалу, квадрат замість прямокутника,
  // стрілка під кратним 45° кутом.
  function even(kind, a, p) {
    const dx = p.x - a.x;
    const dy = p.y - a.y;
    if (kind === 'arrow') {
      const step = Math.PI / 4;
      const angle = Math.round(Math.atan2(dy, dx) / step) * step;
      const len = Math.hypot(dx, dy);
      return { x: a.x + Math.cos(angle) * len, y: a.y + Math.sin(angle) * len };
    }
    const side = Math.max(Math.abs(dx), Math.abs(dy));
    return { x: a.x + Math.sign(dx || 1) * side, y: a.y + Math.sign(dy || 1) * side };
  }

  // Одна фігура. Координати — у пікселях знімка; `scale` — у скільки
  // разів полотно більше за знімок.
  function stroke(ctx, m, scale) {
    ctx.save();
    ctx.strokeStyle = ctx.fillStyle = m.color;
    ctx.lineWidth = m.w;
    ctx.lineCap = ctx.lineJoin = 'round';

    // Легка тінь: без неї біла лінія на білій сторінці зникає, а жовта
    // ледь видна. Розмиття трансформація не масштабує — множимо самі.
    ctx.shadowColor = 'rgba(0, 0, 0, 0.35)';
    ctx.shadowBlur = m.w * scale;

    ctx.beginPath();
    if (m.tool === 'pen') {
      const [first, ...rest] = m.pts;
      if (!rest.length) {
        ctx.arc(first.x, first.y, m.w / 2, 0, Math.PI * 2);
        ctx.fill();
      } else {
        // Через середини відрізків: лінія від руки виходить гладкою, а
        // не ламаною з кутом на кожному русі миші.
        ctx.moveTo(first.x, first.y);
        for (let i = 0; i < rest.length - 1; i++) {
          const p = rest[i];
          const q = rest[i + 1];
          ctx.quadraticCurveTo(p.x, p.y, (p.x + q.x) / 2, (p.y + q.y) / 2);
        }
        const last = rest[rest.length - 1];
        ctx.lineTo(last.x, last.y);
        ctx.stroke();
      }
    } else {
      const { a, b } = m;
      if (m.tool === 'rect') {
        ctx.rect(Math.min(a.x, b.x), Math.min(a.y, b.y), Math.abs(b.x - a.x), Math.abs(b.y - a.y));
        ctx.stroke();
      } else if (m.tool === 'ellipse') {
        ctx.ellipse((a.x + b.x) / 2, (a.y + b.y) / 2,
          Math.abs(b.x - a.x) / 2, Math.abs(b.y - a.y) / 2, 0, 0, Math.PI * 2);
        ctx.stroke();
      } else if (m.tool === 'arrow') {
        arrow(ctx, m);
      }
    }
    ctx.restore();
  }

  function arrow(ctx, { a, b, w }) {
    const len = Math.hypot(b.x - a.x, b.y - a.y);
    if (len < 1) return;

    const angle = Math.atan2(b.y - a.y, b.x - a.x);
    // Вістря росте з товщиною, але не більше за саму стрілку.
    const head = Math.min(w * 4.5, len * 0.6);
    const spread = 0.45;

    // Лінія закінчується всередині вістря: круглий кінець, що дійшов би
    // до самої точки, виглядав би з-під нього горбиком.
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x - Math.cos(angle) * head * 0.8, b.y - Math.sin(angle) * head * 0.8);
    ctx.stroke();

    ctx.beginPath();
    ctx.moveTo(b.x, b.y);
    ctx.lineTo(b.x - head * Math.cos(angle - spread), b.y - head * Math.sin(angle - spread));
    ctx.lineTo(b.x - head * Math.cos(angle + spread), b.y - head * Math.sin(angle + spread));
    ctx.closePath();
    ctx.fill();
  }

  function paint(ctx, scale, list) {
    // Мала зона збільшується по пікселю, без згладжування: розмитий
    // текст на знімку гірший за квадратний.
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(base, 0, 0, ctx.canvas.width, ctx.canvas.height);

    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    for (const m of list) stroke(ctx, m, scale);
  }

  async function markUp(preview, area) {
    if (studio || !base) return;
    try { await base.decode(); } catch { return; }

    const w = base.naturalWidth;
    const h = base.naturalHeight;
    const dpr = window.devicePixelRatio || 1;

    // Вписуємо в екран. Мала зона при цьому збільшується — саме на ній
    // найважче влучити, — але не безмежно. На широкому моніторі смуга
    // на всю ширину вже не допомагає цілитись, а лише змушує водити
    // мишею через увесь стіл.
    const fit = Math.min(
      Math.min(window.innerWidth - 32, 1280) / w,
      (window.innerHeight - 150) / h,
      ZOOM_MAX / dpr,
    );

    // Полотно — це знімок, збільшений у ціле число разів. Мала зона й
    // на виході стає більшою: інакше лінія в чотири екранні пікселі на
    // знімку завширшки в сотню пікселів вийшла б півпікселем.
    const scale = Math.max(1, Math.min(Math.floor(fit * dpr), Math.floor(MAX_SIDE / Math.max(w, h))));

    const before = marks.slice();
    let draft = null;
    let px = 1;   // пікселів знімка в одному CSS-пікселі екрана

    const node = el('div', 'studio');
    node.innerHTML = `
      <div class="tools">
        ${TOOLS.map(([t, key]) => `<button data-tool="${t}" title="${msg(key)}" aria-label="${msg(key)}">${icon(t)}</button>`).join('')}
        <span class="sep"></span>
        ${COLORS.map(([c, key]) => `<button class="swatch" data-color="${c}" title="${msg(key)}" aria-label="${msg(key)}"><i style="background:${c}"></i></button>`).join('')}
        <span class="sep"></span>
        <button data-act="undo" title="${msg('markUndo')}" aria-label="${msg('markUndo')}">${icon('undo')}</button>
        <button data-act="clear" title="${msg('markClear')}" aria-label="${msg('markClear')}">${icon('clear')}</button>
        <span class="sep"></span>
        <button class="text" data-act="cancel">${msg('markCancel')}</button>
        <button class="text primary" data-act="done">${msg('markDone')}</button>
      </div>
      <canvas></canvas>
      <div class="note">${msg('markHint')}</div>
    `;

    const canvas = node.querySelector('canvas');
    canvas.width = w * scale;
    canvas.height = h * scale;
    canvas.style.width = `${Math.round(w * fit)}px`;
    const ctx = canvas.getContext('2d');

    const sync = () => {
      for (const b of node.querySelectorAll('[data-tool]')) b.classList.toggle('on', b.dataset.tool === tool);
      for (const b of node.querySelectorAll('[data-color]')) b.classList.toggle('on', b.dataset.color === color);
      for (const b of node.querySelectorAll('[data-act="undo"], [data-act="clear"]')) b.disabled = !marks.length;
    };

    let queued = false;
    const redraw = () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        if (!studio) return;
        paint(ctx, scale, draft ? [...marks, draft] : marks);
        sync();
      });
    };

    // Точка під курсором — у пікселях знімка.
    const at = (e) => {
      const r = canvas.getBoundingClientRect();
      return { x: (e.clientX - r.left) * (w / r.width), y: (e.clientY - r.top) * (h / r.height) };
    };

    canvas.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      canvas.setPointerCapture(e.pointerId);

      px = w / canvas.getBoundingClientRect().width;
      const p = at(e);
      draft = tool === 'pen'
        ? { tool, color, w: LINE * px, pts: [p] }
        : { tool, color, w: LINE * px, a: p, b: p };
      redraw();
    });

    canvas.addEventListener('pointermove', (e) => {
      if (!draft) return;
      const p = at(e);
      if (draft.tool === 'pen') {
        // Точки, густіші за піксель екрана, лише роздувають фігуру.
        const last = draft.pts[draft.pts.length - 1];
        if (Math.hypot(p.x - last.x, p.y - last.y) < px) return;
        draft.pts.push(p);
      } else {
        draft.b = e.shiftKey ? even(draft.tool, draft.a, p) : p;
      }
      redraw();
    });

    const finish = () => {
      if (!draft) return;
      const m = draft;
      draft = null;
      // Клік фігурою без протягування — промах, а не фігура.
      const missed = m.tool !== 'pen' && Math.hypot(m.b.x - m.a.x, m.b.y - m.a.y) < 3 * px;
      if (!missed) marks.push(m);
      redraw();
    };
    canvas.addEventListener('pointerup', finish);
    canvas.addEventListener('pointercancel', finish);

    async function close(keep) {
      if (!studio) return;
      if (!keep) marks = before;

      const changed = marks.length !== before.length || marks.some((m, i) => m !== before[i]);

      // Знімаємо до того, як прибрати полотно, і без недомальованої
      // фігури: у кадрі має бути рівно те, що користувач бачить.
      let image = null;
      if (keep && changed && marks.length) {
        draft = null;
        paint(ctx, scale, marks);
        image = canvas.toDataURL('image/png');
      }

      node.remove();
      studio = null;

      if (!keep || !changed) { area.focus(); return; }

      // Поки знімок їде у service worker, Enter не має відправити старий.
      area.disabled = true;
      const res = await chrome.runtime.sendMessage({ type: 'lb:mark', image })
        .catch((err) => ({ ok: false, error: err.message }));
      area.disabled = false;
      area.focus();

      if (!res?.ok) { marks = before; fail(res?.error || msg('errMark'), card); return; }
      preview.src = res.preview;
    }

    node.querySelector('.tools').addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b || b.disabled) return;
      if (b.dataset.act === 'cancel') { close(false); return; }
      if (b.dataset.act === 'done') { close(true); return; }
      if (b.dataset.tool) tool = b.dataset.tool;
      if (b.dataset.color) color = b.dataset.color;
      if (b.dataset.act === 'undo') marks.pop();
      if (b.dataset.act === 'clear') marks = [];
      redraw();
    });

    // Редактор модальний: сторінка під ним не має чути жодної клавіші.
    // Клавіші — за кодом, а не за символом: на українській розкладці
    // ⌘Z приходить як «я».
    const onKey = (e) => {
      e.stopPropagation();
      if (e.key === 'Escape') close(false);
      else if (e.key === 'Enter') close(true);
      else if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.code === 'KeyZ') { marks.pop(); redraw(); }
      else return;
      e.preventDefault();
    };

    studio = { el: node, onKey };
    area.blur();
    redraw();
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

  function toast(message, ms = 2200) {
    const t = el('div', 'toast');
    t.textContent = message;
    setTimeout(() => t.remove(), ms);
  }

  document.documentElement.appendChild(host);
  window.__laserbeakOverlay = { begin };

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type === 'lb:begin') begin();
  });
})();
