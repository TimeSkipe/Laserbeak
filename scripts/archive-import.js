#!/usr/bin/env node
'use strict';

// Разовий імпорт усієї переписки, яка ще лежить на диску.
//
//   node scripts/archive-import.js [--dry]
//
// Claude Code тримає транскрипти близько 30 днів, а потім прибирає їх.
// Цей скрипт забирає в архів усе, що ще не встигло зникнути, — після
// нього демон лише дописує нове.
//
// Демон при цьому можна не зупиняти: запис іде через ту саму логіку зі
// зсувами й дедуплікацією за uuid, тож повторний запуск нічого не псує.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');

const config = require('../src/config');
const roots = require('../src/roots');
const archive = require('../src/archive');

const PROJECTS_DIR = path.join(os.homedir(), '.claude', 'projects');
const dryRun = process.argv.includes('--dry');

/**
 * Демон тримає індекс архіву в пам'яті й періодично його переписує.
 * Якщо імпортувати паралельно, він затре нашу роботу своєю копією.
 */
function daemonIsRunning() {
  try {
    const out = execSync(
      `curl -s -m 2 http://127.0.0.1:${config.get().port}/health`,
      { encoding: 'utf8' },
    );
    return out.includes('"ok":true');
  } catch {
    return false;
  }
}

/**
 * Робочий каталог сесії беремо з самого транскрипту.
 *
 * З назви теки його не відновити: Claude Code кодує шлях, замінюючи "/"
 * на "-", а назви проєктів самі містять дефіси — atlas-api-v3 при
 * зворотному розборі перетворювався б на "v3".
 */
function cwdFromTranscript(file) {
  let handle;
  try {
    handle = fs.openSync(file, 'r');
    const buffer = Buffer.allocUnsafe(64 * 1024);
    const read = fs.readSync(handle, buffer, 0, buffer.length, 0);
    const head = buffer.toString('utf8', 0, read);

    for (const line of head.split('\n')) {
      if (!line) continue;
      try {
        const record = JSON.parse(line);
        if (record.cwd) return record.cwd;
      } catch { /* рядок обрізаний буфером */ }
    }
  } catch {
    return '';
  } finally {
    if (handle !== undefined) try { fs.closeSync(handle); } catch { /* вже закрито */ }
  }

  return '';
}

function walk(dir, out = []) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }

  for (const entry of entries) {
    const full = path.join(dir, entry.name);

    // Підагенти лежать в окремій теці — це бічні гілки, не головна розмова.
    if (entry.isDirectory()) {
      if (entry.name === 'subagents') continue;
      walk(full, out);
    } else if (entry.name.endsWith('.jsonl')) {
      out.push(full);
    }
  }

  return out;
}

function main() {
  if (!fs.existsSync(PROJECTS_DIR)) {
    console.error(`немає теки ${PROJECTS_DIR}`);
    return 1;
  }

  const files = walk(PROJECTS_DIR);
  console.log(`знайдено транскриптів: ${files.length}`);

  if (!dryRun && daemonIsRunning()) {
    console.error();
    console.error('✖ демон працює — він затре індекс архіву своєю копією.');
    console.error('  Зупини його, імпортуй, запусти назад:');
    console.error();
    console.error('    launchctl bootout gui/$(id -u)/com.laserbeak.daemon');
    console.error('    node scripts/archive-import.js');
    console.error('    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.laserbeak.daemon.plist');
    return 1;
  }

  if (dryRun) {
    const bytes = files.reduce((sum, f) => {
      try { return sum + fs.statSync(f).size; } catch { return sum; }
    }, 0);
    console.log(`сумарний розмір: ${(bytes / 1024 / 1024).toFixed(1)} МБ`);
    console.log('(пробний запуск, нічого не записано)');
    return 0;
  }

  let imported = 0;
  let messages = 0;
  let skipped = 0;

  for (const file of files) {
    const sid = path.basename(file, '.jsonl');
    const cwd = cwdFromTranscript(file);
    const projectPath = cwd ? roots.resolve(cwd) : '';

    const before = archive.meta(sid)?.messages || 0;
    const entry = archive.ingest(sid, file, {
      project: projectPath ? path.basename(projectPath) : '',
      projectPath,
    });

    const added = (entry?.messages || 0) - before;
    if (added > 0) {
      imported += 1;
      messages += added;
      const when = entry.lastTs ? new Date(entry.lastTs).toISOString().slice(0, 10) : '—';
      console.log(`  ${when}  ${entry.project.padEnd(22)} +${added}`);
    } else {
      skipped += 1;
    }
  }

  console.log();
  console.log(`імпортовано сесій:   ${imported}`);
  console.log(`нових повідомлень:   ${messages}`);
  console.log(`без змін:            ${skipped}`);
  console.log(`архів:               ${archive.ARCHIVE_DIR}`);
  return 0;
}

process.exitCode = main();
