// The hook that tells an agent to compact before its prompt cache goes cold.
// The side panel's "Compact before it goes cold" off sets the zmx label compact=0 on the tab, read before prompting.
// Run: claude plugin test app/apple/ClaudeTTY/plugin
import { describe, expect, mock, test } from 'claude-code/testing'
import type { On, PromptSubmitInput, SessionStartInput, TurnCompleteInput } from 'claude-code'

const MIN = 60 * 1000
const HOUR = 60 * MIN
const T = 10 * HOUR
const HOME = '/home/me'
const STORE_DIR = `${HOME}/.claude/plugins/store`
// Another user's marketplace and hash: the file is found by its cache-tax_ prefix, not by the user's name for it.
const CACHE_TAX_FILE = 'cache-tax_their-market-0123456789ab.json'

const session: SessionStartInput = { surface: 'terminal', isInteractive: true, cwd: '/work' }

let turns = 0
const turn = (over: Record<string, unknown> = {}): TurnCompleteInput => ({
  answer: 'ok', durationMs: 1000, isAborted: false, turnId: 't' + ++turns, reason: 'answer',
  usage: { input_tokens: 2, output_tokens: 10, cache_read_input_tokens: 200000, cache_creation_input_tokens: 500, model: 'claude-fable-5-1' }, ...over,
} as TurnCompleteInput)

const typed = (text: string): PromptSubmitInput => ({ text, wait: false, origin: { kind: 'composer' } })

// The world beneath the plugin: a tab (or none), the live context, cache-tax's store file (or none),
// and every prompt that reaches the agent, with whose it was.
// The tab's zmx labels as `zmx get <tab>` prints them (space-separated key=value), read at the time of the call.
function world(on: On, opts: { tab?: string; tokens?: { value: number }; cacheTax?: Record<string, number>; labels?: { value: string } } = {}) {
  const labels = opts.labels ?? { value: 'group=CLAUDETTY' }
  const tokens = opts.tokens ?? { value: 120000 }
  const prompts: Array<{ text: string; kind: string }> = []
  const at = (path: string) => path.replace(/^~/, HOME)
  mock.store(on, {})
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : e.name === 'ZMX_SESSION' ? opts.tab : undefined }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'S1' }))
  on('session.model', () => ({ value: 'claude-fable-5-1' }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 1000000, tokens: tokens.value }, rateLimits: [] } }))
  on('turn.complete', ($, e) => ({ text: (e as { answer?: string }).answer }))
  on('prompt.submit', ($, e) => { prompts.push({ text: e.text, kind: e.origin?.kind ?? 'unknown' }); return { text: e.text } })
  on('session.compact', ($, e) => ({ messages: e.messages }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('command.list', () => ({ value: [] }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.status', () => ({ value: undefined }))
  on('process.run', ($, e) => {
    const line = e.argv.join(' ')
    if (opts.tab && /zmx\b.*\bget\b/.test(line) && line.includes(opts.tab)) return { value: { exitCode: 0, stdout: labels.value + '\n', stderr: '' } as never }
    return { value: { exitCode: 1, stdout: '', stderr: `not in this world: ${line}` } as never }
  })
  const has = (path: string) => opts.cacheTax !== undefined && (at(path) === STORE_DIR || at(path) === `${STORE_DIR}/${CACHE_TAX_FILE}`)
  on('fs.list', ($, e) => {
    if (opts.cacheTax && at(e.path) === STORE_DIR) return { value: [{ name: 'other_builtin-b049b47b3618.json', kind: 'file' }, { name: CACHE_TAX_FILE, kind: 'file' }] as never }
    throw new Error(`ENOENT: no such file or directory, scandir '${e.path}'`)
  })
  on('fs.read', ($, e) => {
    if (opts.cacheTax && at(e.path) === `${STORE_DIR}/${CACHE_TAX_FILE}`) return { value: JSON.stringify(opts.cacheTax) }
    throw new Error(`ENOENT: no such file or directory, open '${e.path}'`)
  })
  on('fs.exists', ($, e) => ({ value: has(e.path) }))
  on('fs.stat', ($, e) => {
    if (!has(e.path)) throw new Error(`ENOENT: no such file or directory, stat '${e.path}'`)
    return { value: { kind: at(e.path) === STORE_DIR ? 'dir' : 'file', size: 0, mtimeMs: T } as never }
  })
  // Only what the plugin itself submitted: the compact prompts.
  const told = () => prompts.filter(p => p.kind === 'plugin').map(p => p.text)
  return { prompts, told }
}

describe('compact before the cache goes cold', () => {
  test('an idle agent in a tab is told once, about 5 minutes before the cache goes cold, how to compact itself', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const w = world(on, { tab: 'asst' })
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(50 * MIN)
    // not long before the cache's last minutes
    expect(w.told()).toEqual([])
    await clock.advance(9 * MIN)
    // one prompt, before the 1 h cache goes cold
    expect(w.told().length).toBe(1)
    const text = w.told()[0] ?? ''
    // names the command
    expect(text).toMatch(/\/compact\b/)
    // gives it a way to type that into its own tab
    expect(text).toMatch(/zmx send/)
    expect(text).toMatch(/\$ZMX_SESSION|\basst\b/)
    // nothing only the user's machine has
    expect(text).not.toMatch(/session\.sh/)
  })

  test('outside a ClaudeTTY tab it never prompts (declared future-guard)', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const w = world(on, {})
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(3 * HOUR)
    // a ClaudeTTY feature, silent outside its tabs
    expect(w.told()).toEqual([])
  })

  test('only a context of 50 000 tokens or more is told to compact', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const tokens = { value: 49999 }
    const w = world(on, { tab: 'asst', tokens })
    await $.session.start(session)
    await $.prompt.submit(typed('small'))
    await $.turn.complete(turn())
    await clock.advance(59 * MIN)
    // nothing worth compacting under 50k
    expect(w.told()).toEqual([])
    tokens.value = 50000
    await $.prompt.submit(typed('bigger'))
    await $.turn.complete(turn())
    await clock.advance(59 * MIN)
    // at 50k it is told
    expect(w.told().length).toBe(1)
  })

  test('a subagent\'s turn does not move the deadline', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const w = world(on, { tab: 'asst' })
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(30 * MIN)
    await $.turn.complete(turn({ agentId: 'worker' }))
    await clock.advance(29 * MIN)
    // the main agent's cache goes cold 1 h after its own last request
    expect(w.told().length).toBe(1)
  })

  test('once per idle stretch: its own reply never re-arms it, and the next prompt of his starts a new stretch', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const w = world(on, { tab: 'asst' })
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(59 * MIN)
    expect(w.told().length).toBe(1)
    // The agent answers the plugin's prompt (and, say, decides not to compact).
    await $.turn.complete(turn())
    await clock.advance(3 * HOUR)
    // one per idle stretch, never a loop off its own reply
    expect(w.told().length).toBe(1)
    await $.prompt.submit(typed('back'))
    await $.turn.complete(turn())
    await clock.advance(59 * MIN)
    // a new stretch after the user's own prompt
    expect(w.told().length).toBe(2)
  })

  test('never right after a compaction with no turn since', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const w = world(on, { tab: 'asst' })
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(20 * MIN)
    await $.session.compact({ trigger: 'manual', messages: [{ role: 'user', text: 'summary', toolUses: [] }] })
    await clock.advance(3 * HOUR)
    // not one that just did
    expect(w.told()).toEqual([])
    await $.prompt.submit(typed('next'))
    await $.turn.complete(turn())
    await clock.advance(59 * MIN)
    // a turn after the compaction arms it again
    expect(w.told().length).toBe(1)
  })

  test('a prompt before it is due cancels it, and the next finished turn arms it again', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const w = world(on, { tab: 'asst' })
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(40 * MIN)
    // A long turn starts and is still running when the old deadline passes.
    await $.prompt.submit(typed('one more thing'))
    await clock.advance(60 * MIN)
    // never into a session that is working
    expect(w.told()).toEqual([])
    await $.turn.complete(turn())
    await clock.advance(50 * MIN)
    expect(w.told()).toEqual([])
    await clock.advance(9 * MIN)
    // timed from the turn that just ended
    expect(w.told().length).toBe(1)
  })

  test('a keepwarm ping in cache-tax\'s store pushes the deadline to that ping plus an hour', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const cacheTax: Record<string, number> = { 'deadline:S1': T + 6 * HOUR, 'deadline:S0': T + HOUR }
    const w = world(on, { tab: 'asst', cacheTax })
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(50 * MIN)
    // cache-tax pings and records it, as it does under `last:<session id>`.
    cacheTax['last:S1'] = clock.now()
    await clock.advance(50 * MIN)
    // the ping kept the cache warm, so not yet
    expect(w.told()).toEqual([])
    await clock.advance(9 * MIN)
    // about 5 minutes before the ping's hour runs out
    expect(w.told().length).toBe(1)
  })

  test('a tab labeled compact=0 (the side panel\'s "Compact before it goes cold" off) is never told, and is again once the label goes', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const labels = { value: 'group=CLAUDETTY claude=S1 compact=0' }
    const w = world(on, { tab: 'asst', labels })
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(59 * MIN)
    // switched off for this tab, the hook stays quiet
    expect(w.told()).toEqual([])
    await clock.advance(3 * HOUR)
    expect(w.told()).toEqual([])
    // Switched back on: the panel takes the label off.
    labels.value = 'group=CLAUDETTY claude=S1'
    await $.prompt.submit(typed('back'))
    await $.turn.complete(turn())
    await clock.advance(59 * MIN)
    // on again, it tells
    expect(w.told().length).toBe(1)
  })

  test('the label is read when the prompt is due, not when the turn ended', async ($, on) => {
    const clock = mock.clock(on, { now: T })
    const labels = { value: 'group=CLAUDETTY claude=S1' }
    const w = world(on, { tab: 'asst', labels })
    await $.session.start(session)
    await $.prompt.submit(typed('build it'))
    await $.turn.complete(turn())
    await clock.advance(30 * MIN)
    // The user switches it off in the panel while the tab sits idle.
    labels.value = 'group=CLAUDETTY claude=S1 compact=0'
    await clock.advance(29 * MIN)
    // none reaches the agent after the switch
    expect(w.told()).toEqual([])
  })
})
