#!/usr/bin/env node
'use strict';

// laserbeak — точка входу. Живе у фоні як LaunchAgent.

const fs = require('fs');
const config = require('./config');
const { CONFIG_PATH, DATA_DIR } = require('./paths');
const { createServer } = require('./server');
const bonjour = require('./bonjour');
const notify = require('./notify');
const state = require('./state');
const archive = require('./archive');
const terminals = require('./terminals');
const tmux = require('./tmux');
const modes = require('./modes');
const reaper = require('./reaper');
const appguard = require('./appguard');
const log = require('./log');

if (!fs.existsSync(CONFIG_PATH)) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(config.DEFAULTS, null, 2) + '\n');
  log.info(`створив ${CONFIG_PATH}`);
  config.load();
}

config.watch();

const cfg = config.get();
const server = createServer();

server.on('error', (e) => {
  log.error(e.code === 'EADDRINUSE'
    ? `порт ${cfg.port} зайнятий — схоже, демон уже запущено`
    : `сервер: ${e.message}`);
  process.exit(1);
});

server.listen(cfg.port, cfg.bindHost, () => {
  log.info(`laserbeak слухає ${cfg.bindHost}:${cfg.port} (pid ${process.pid})`);
  log.info(`дані: ${DATA_DIR}`);

  if (!notify.isNotifierInstalled()) {
    log.warn('terminal-notifier не знайдено — банери через osascript (менш надійно)');
  }

  if (cfg.bindHost !== '127.0.0.1') {
    bonjour.start({ name: cfg.serviceName, port: cfg.port });
  } else {
    log.info('bindHost = 127.0.0.1 — у мережі нас не видно; телефон ходить через програму на маку');
  }

  // Програма на маку тримає єдиний канал до телефона, тож стежимо, щоб
  // вона була жива. Подробиці, зокрема чому не KeepAlive, — у appguard.js.
  appguard.start();
});

// Переписку живих сесій дочитуємо постійно, а не лише на подіях хуків.
// Інакше посеред довгої відповіді історія відставала б: хук stop
// прилітає аж наприкінці турна, і до того нове в архів не потрапляло.
//
// Коштує це майже нічого: читання інкрементне, і коли транскрипт не
// виріс, усе зводиться до одного statSync.
const LIVE_ARCHIVE_MS = 2000;

setInterval(() => {
  // Сесії, про які демон знає з хуків: у них є свіжі мітка і проєкт.
  for (const session of state.sessions.values()) {
    if (!session.transcript) continue;
    try {
      archive.ingest(session.sid, session.transcript, {
        label: session.label,
        project: session.project,
        projectPath: session.projectPath,
      });
    } catch (e) {
      log.warn(`архів ${session.sid}: ${e.message}`);
    }
  }

  // Плюс усе, що нещодавно змінювалось на диску. Це рятує випадок, коли
  // демон перезапустили посеред роботи: у памʼяті сесій ще немає, але
  // транскрипти з індексу нікуди не поділись.
  try {
    archive.ingestRecent();
  } catch (e) {
    log.warn(`архів: ${e.message}`);
  }
}, LIVE_ARCHIVE_MS).unref();

// Прибирання мертвих сесій. Сама перевірка — у src/reaper.js, бо те саме
// вміє робити кнопка «Оновити» в програмі.
//
// Півхвилини, а не півгодини: перевірка коштує один виклик tmux і дає
// точну відповідь, а мертва сесія у списку збиває з пантелику.
const REAP_MS = 30_000;

setInterval(() => {
  try {
    reaper.reap();
  } catch (e) {
    log.warn(`перевірка сесій: ${e.message}`);
  }
}, REAP_MS).unref();

process.on('uncaughtException', (e) => log.error(`uncaught: ${e.stack || e}`));
process.on('unhandledRejection', (e) => log.error(`unhandled: ${(e && e.stack) || e}`));

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    log.info(`отримав ${sig}, зупиняюсь`);
    bonjour.stop();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000).unref();
  });
}
