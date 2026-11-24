import type { EngineInterface, Register } from 'claude-code'

const TTL_MS = 60 * 60 * 1000
// Room for the agent's answer, which itself reads the cache, before the hour runs out.
const LEAD_MS = 5 * 60 * 1000
const BIG_TOKENS = 50000
// Pasted (bracketed): typed keys in a vim normal-mode prompt box are commands, and "/compact" arrived as "ct".
const PROMPT = 'Your prompt cache goes cold in about 5 minutes. If this thread will continue, compact now while it\'s cheap: follow your project\'s compaction steps if it has any (CLAUDE.md), otherwise run `zmx send "$ZMX_SESSION" $\'\\e[200~/compact\\e[201~\'` and then `zmx send "$ZMX_SESSION" $\'\\r\'`, and it runs as soon as this turn ends. Otherwise note where you are and stay idle.'

type State = { tab: string; home: string; lastRequestAt: number; told: boolean; pending: { cancel: () => void } | null }

function disarm(s: State) {
  s.pending?.cancel()
  s.pending = null
}

// cache-tax's keepwarm pings run no turn here; the last one it stored keeps the cache warm as well.
async function lastPing($: EngineInterface, s: State): Promise<number> {
  const dir = `${s.home}/.claude/plugins/store`
  const sid = await $.session.id()
  let last = 0
  for (const file of await $.fs.list(dir).catch(() => [])) {
    if (!file.name.startsWith('cache-tax_')) continue
    const store = await $.fs.read(`${dir}/${file.name}`).then(text => JSON.parse(text as string)).catch(() => null)
    const at = store?.[`last:${sid}`]
    if (typeof at === 'number' && at > last) last = at
  }
  return last
}

async function check($: EngineInterface, s: State) {
  s.pending = null
  const coldAt = Math.max(s.lastRequestAt, await lastPing($, s)) + TTL_MS
  const now = await $.clock.now()
  if (now < coldAt - LEAD_MS) {
    s.pending = $.clock.after(coldAt - LEAD_MS - now, () => { void check($, s) })
    return
  }
  // Already cold (a sleeping Mac fires late): compacting now pays the full write it was meant to save.
  if (now >= coldAt || ((await $.session.usage()).context.tokens ?? 0) < BIG_TOKENS) return
  // The side panel's "Compact before it goes cold" off labels the tab compact=0, read when the prompt is due.
  const labels = await $.process.run([`${s.home}/.local/bin/zmx`, 'get', s.tab]).catch(() => null)
  if (labels?.stdout.split(/\s+/).includes('compact=0')) return
  s.told = true
  void $.prompt.submit({ text: PROMPT })
}

/** Tells an idle agent in a ClaudeTTY tab to compact while its prompt cache is still warm, once per idle stretch. */
export const register: Register = on => {
  const s: State = { tab: '', home: '', lastRequestAt: 0, told: false, pending: null }

  on('session.start', async ($, e, next) => {
    const r = await next(e)
    s.tab = (await $.env.get('ZMX_SESSION')) ?? ''
    s.home = (await $.env.get('HOME')) ?? ''
    return r
  })

  on('prompt.submit', async ($, e, next) => {
    disarm(s)
    // Only a prompt other than its own starts a new idle stretch: the agent's answer to it never re-arms it.
    if (e.text !== PROMPT) s.told = false
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (!s.tab || e.agentId || s.told) return r
    s.lastRequestAt = await $.clock.now()
    disarm(s)
    await check($, s)
    return r
  })

  // A compaction leaves nothing worth compacting until the next turn.
  on('session.compact', async ($, e, next) => {
    const r = await next(e)
    if (!e.agentId) disarm(s)
    return r
  })
}
