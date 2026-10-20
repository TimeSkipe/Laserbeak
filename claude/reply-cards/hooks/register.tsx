import type { Register } from 'claude-code'

type Part =
  | { kind: 'markdown'; text: string }
  | { kind: 'card'; number: string; title: string; body: string }

const CARD_START = /^(\d+)[.)]\s+\*\*(.+?)\*\*\s*$/
const LETTERED = /^[a-z][.)]\s/
const INDENTED = /^\s{2,}\S/

const QUESTION_TITLE = /питан|запитан|вирішуєте|вирішуєш|otázk|dotaz|rozhoduj|question|your decision/i
const IMPORTANT_TITLE = /важлив|увага|důležit|pozor|upozorn|important/i

const PURPLE = '#a78bfa'
const YELLOW = '#facc15'
const LIGHT_BLUE = '#7dd3fc'

const colorOf = (title: string): string => {
  if (QUESTION_TITLE.test(title)) {
    return PURPLE
  }
  if (IMPORTANT_TITLE.test(title)) {
    return YELLOW
  }
  return LIGHT_BLUE
}

const FORMAT_RULE = {
  id: 'reply-cards:format',
  scope: 'session',
  text: [
    'Reply layout (the reply-cards mod draws it as colored cards):',
    '- When a reply has distinct parts, write each as a card: `1. **Title**` alone on its line, the body indented 3 spaces on the lines below. Number the cards 1, 2, 3 in reading order.',
    '- Sub-items inside a card are lettered and indented with the body: `   a. ...`, `   b. ...`.',
    '- What the user should know or watch out for goes in a card titled "Important" in the user\'s language (Ukrainian `Важливо знати`, Czech `Důležité`); it is drawn yellow.',
    '- Questions to the user go in the last card, titled "Questions" in the user\'s language (Ukrainian `Питання`, Czech `Otázky`), one question per line; a decision only the user can make goes there too. It is drawn purple. Never write questions as checkboxes.',
    '- Every other card (what changed, what you took as decided, facts) is drawn light blue.',
    '- Everything else (a one-line lead, a closing sentence) is plain text outside the cards. A short reply needs no cards.',
  ].join('\n'),
} as const

const dedent = (lines: string[]): string => {
  const indents = lines.filter(line => line.trim()).map(line => line.length - line.trimStart().length)
  const shift = indents.length ? Math.min(...indents) : 0
  const out: string[] = []
  for (const line of lines.map(line => line.slice(shift))) {
    const previous = out[out.length - 1]
    if (LETTERED.test(line) && previous !== undefined && previous.trim() !== '') {
      out.push('')
    }
    out.push(line)
  }
  return out.join('\n').trim()
}

const nextFilled = (lines: string[], from: number): number => {
  let at = from
  while (at < lines.length && (lines[at] ?? '').trim() === '') {
    at++
  }
  return at
}

export const parseReply = (text: string): Part[] => {
  const lines = text.split('\n')
  const parts: Part[] = []
  let plain: string[] = []

  const flush = () => {
    const joined = plain.join('\n').trim()
    if (joined) {
      parts.push({ kind: 'markdown', text: joined })
    }
    plain = []
  }

  let i = 0
  while (i < lines.length) {
    const line = lines[i] ?? ''
    const card = CARD_START.exec(line)

    if (!card) {
      plain.push(line)
      i++
      continue
    }

    flush()
    const body: string[] = []
    i++
    while (i < lines.length) {
      const current = lines[i] ?? ''
      if (current.trim() === '') {
        const after = nextFilled(lines, i)
        if (after < lines.length && INDENTED.test(lines[after] ?? '')) {
          body.push('')
          i++
          continue
        }
        break
      }
      if (!INDENTED.test(current)) {
        break
      }
      body.push(current)
      i++
    }
    parts.push({ kind: 'card', number: card[1] ?? '', title: card[2] ?? '', body: dedent(body) })
  }

  flush()
  return parts
}

export const register: Register = on => {
  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    return { sections: [...composed.sections, FORMAT_RULE] }
  })

  on('ui.render', { component: 'AssistantMessage' }, ($, e, next) => {
    if (e.props.isSummary) {
      return next(e)
    }

    const parts = parseReply(e.props.text)
    if (!parts.some(part => part.kind === 'card')) {
      return next(e)
    }

    const { Box, Text, Markdown } = $.ui.resolve(e)

    return (
      <Box flexDirection="column" gap={1}>
        {parts.map((part, index) => {
          if (part.kind === 'markdown') {
            return <Markdown text={part.text} />
          }

          const color = colorOf(part.title)

          return (
            <Box key={`card-${index}`} flexDirection="column" borderStyle="round" borderColor={color} paddingX={1}>
              <Box flexDirection="row" gap={1}>
                <Text dimColor>{part.number}</Text>
                <Text bold color={color}>{part.title}</Text>
              </Box>
              {part.body ? <Markdown text={part.body} /> : null}
            </Box>
          )
        })}
      </Box>
    )
  })
}
