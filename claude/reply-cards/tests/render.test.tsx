import { expect, test } from 'claude-code/testing'

const REPLY = [
  'Скіл і мод готові.',
  '',
  '1. **Що зроблено**',
  '   Мод малює картки.',
  '',
  '2. **Важливо знати**',
  '   a. кнопки прибрані',
  '   b. кольори за назвою картки',
  '',
  '3. **Питання**',
  '   Підключити мод у всі сесії?',
].join('\n')

test('cards are colored by their title and carry no buttons', async $ => {
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({
      plugin: 'reply-cards',
      surface,
      component: 'AssistantMessage',
      props: { text: REPLY, isFirstOfReply: true },
    })

    expect((await ui.find({ type: 'Text', text: 'Що зроблено' }))?.props.color).toBe('#7dd3fc')
    expect((await ui.find({ type: 'Text', text: 'Важливо знати' }))?.props.color).toBe('#facc15')
    expect((await ui.find({ type: 'Text', text: 'Питання' }))?.props.color).toBe('#a78bfa')
    expect(await ui.find({ type: 'Button' })).toBeUndefined()

    await ui.unmount()
  }
})

test('a reply without cards is drawn by the engine', async ($, on) => {
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({
      plugin: 'reply-cards',
      surface,
      component: 'AssistantMessage',
      props: { text: 'Jen krátká odpověď bez karet.', isFirstOfReply: true },
    })

    expect(await ui.find({ type: 'Text', text: 'engine' })).toBeDefined()

    await ui.unmount()
  }
})
