'use strict';

// Оголошення демона в локальній мережі через Bonjour.
//
// Завдяки цьому застосунок на телефоні знаходить ноут сам — не треба
// вбивати IP руками, і все продовжує працювати, коли роутер видасть
// комп'ютеру іншу адресу.
//
// Використовується /usr/bin/dns-sd — він є в macOS з коробки, тому
// жодних npm-залежностей. Процес живе, доки живе демон.

const { spawn } = require('child_process');
const log = require('./log');

const SERVICE_TYPE = '_laserbeak._tcp';

let child = null;
let stopping = false;

function start({ name, port }) {
  stop();
  stopping = false;

  child = spawn('/usr/bin/dns-sd', ['-R', name, SERVICE_TYPE, 'local', String(port)], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });

  child.on('error', (e) => log.error(`bonjour: ${e.message}`));

  child.stderr?.on('data', (d) => {
    const msg = String(d).trim();
    if (msg) log.warn(`bonjour: ${msg}`);
  });

  child.on('exit', (code) => {
    child = null;
    if (stopping) return;
    log.warn(`bonjour: dns-sd вийшов (код ${code}), піднімаю через 5с`);
    setTimeout(() => start({ name, port }), 5000);
  });

  log.info(`bonjour: оголошую "${name}" як ${SERVICE_TYPE} на порті ${port}`);
}

function stop() {
  stopping = true;
  if (child) {
    child.kill();
    child = null;
  }
}

module.exports = { start, stop, SERVICE_TYPE };
