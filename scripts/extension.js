#!/usr/bin/env node
'use strict';

// npm run extension — шлях до теки розширення в буфер і підказка, що
// натиснути. Раніше це був рядок у package.json, і лише українською.

const path = require('path');
const { execFileSync } = require('child_process');
const { t } = require('./lang');

const dir = path.resolve(__dirname, '..', 'extension');
execFileSync('pbcopy', { input: dir });
console.log(`\n  ${t('ext.copied')}\n  ${dir}\n\n  ${t('ext.how')}\n`);
