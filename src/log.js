'use strict';

// stdout перехоплює launchd і пише у ~/.laserbeak/daemon.log

function stamp() {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

function write(level, msg) {
  process.stdout.write(`[${stamp()}] ${level} ${msg}\n`);
}

module.exports = {
  info: (msg) => write('·', msg),
  warn: (msg) => write('⚠', msg),
  error: (msg) => write('✖', msg),
};
