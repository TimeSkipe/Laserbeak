'use strict';

// Визначення кореня проєкту за робочим каталогом сесії.
//
// Claude можна запустити в будь-якій підтеці — наприклад у my-app або
// functions усередині одного проєкту. Якщо брати робочий каталог як є,
// кожна така підтека стає окремим «проєктом», і замість одного рядка в
// списку з'являється три.
//
// Порядок пошуку кореня:
//   1. проєкт, відкритий в IDE, який містить цей каталог — найточніше,
//      бо це саме те, що користувач вважає проєктом;
//   2. найближчий предок із .git або .idea — працює без запущеної IDE;
//   3. сам каталог, якщо нічого не знайшлося.

const fs = require('fs');
const path = require('path');
const inspect = require('./inspect');

const MARKERS = ['.git', '.idea'];

// Відповідь для одного каталогу не змінюється, а хуки сиплються часто.
const cache = new Map();
const CACHE_TTL_MS = 30_000;

function fromOpenProjects(cwd) {
  const open = inspect.snapshot().openProjects;
  if (!open || !open.size) return null;

  let best = null;
  for (const root of open) {
    const prefix = root.endsWith('/') ? root : root + '/';
    if (cwd !== root && !cwd.startsWith(prefix)) continue;
    if (!best || root.length > best.length) best = root;
  }
  return best;
}

function fromMarkers(cwd) {
  let dir = cwd;

  while (true) {
    for (const marker of MARKERS) {
      try {
        if (fs.existsSync(path.join(dir, marker))) return dir;
      } catch {
        // немає прав — просто йдемо вище
      }
    }

    const parent = path.dirname(dir);
    if (parent === dir) return null;   // дійшли до кореня файлової системи
    dir = parent;
  }
}

/** @returns {string} каталог, який слід вважати проєктом */
function resolve(cwd) {
  if (!cwd) return '';

  const cached = cache.get(cwd);
  if (cached && Date.now() - cached.at < CACHE_TTL_MS) return cached.root;

  const root = fromOpenProjects(cwd) || fromMarkers(cwd) || cwd;
  cache.set(cwd, { at: Date.now(), root });
  return root;
}

module.exports = { resolve };
