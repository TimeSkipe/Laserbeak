'use strict';

// Написати в сесію так, ніби текст набрали з клавіатури.
//
// Шляхів два, і вибір між ними потрібен усім, хто щось шле в сесію:
// і звичайному запиту з програми, і слеш-командам на кшталт /model.
// Тому логіка живе тут, а не в обробнику одного маршруту.
//
//   сесія запущена демоном  → пишемо у власний псевдотермінал
//   сесія в tmux            → send-keys у панель
//   інакше                  → написати неможливо, і це не полагодити
//                             (майстра псевдотермінала тримає WebStorm,
//                              а TIOCSTI macOS прибрала)

const terminals = require('./terminals');
const tmux = require('./tmux');
const state = require('./state');
const { t } = require('./i18n');

class NoWayIn extends Error {
  constructor() {
    super(t('err.noWayIn'));
    this.name = 'NoWayIn';
  }
}

/**
 * @param {string} sid
 * @param {string} text
 * @returns {{via: 'terminal'|'tmux'}}
 */
function send(sid, text) {
  if (terminals.isHosted(sid)) {
    terminals.write(sid, text);
    return { via: 'terminal' };
  }

  const session = state.get(sid);
  if (session?.tmuxPane) {
    tmux.send(session.tmuxPane, text);
    return { via: 'tmux' };
  }

  throw new NoWayIn();
}

/** Чи можна взагалі писати в цю сесію. */
function canSend(sid) {
  if (terminals.isHosted(sid)) return true;
  return Boolean(state.get(sid)?.tmuxPane);
}

module.exports = { send, canSend, NoWayIn };
