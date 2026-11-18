// Claude Progress - hook script.
// Claude Code runs this on: UserPromptSubmit (turn starts), PreToolUse (step starts),
// PostToolUse / PostToolUseFailure (step ends) and Stop (turn ends). It reads the event
// JSON from stdin and updates two files in %USERPROFILE%\.claude-progress:
//   state.json   - what is running now plus this turn's activity log (the window reads it)
//   history.json - how long past steps took (used for the time estimates)
// It never prints anything and always exits 0, so it can never block Claude.

const fs = require('fs')
const path = require('path')
const os = require('os')

const DIR = process.env.CLAUDE_PROGRESS_DIR || path.join(os.homedir(), '.claude-progress')
const STATE = path.join(DIR, 'state.json')
const HISTORY = path.join(DIR, 'history.json')
const KEEP = 12
const LOG_MAX = 60
const RENDER = /render|ffmpeg|blender|remotion|magick|export|build|puppeteer|playwright|convert/i

const readJson = (file, fallback) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return fallback }
}
const writeJson = (file, value) => {
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value))
  fs.renameSync(tmp, file)
}
const median = xs => {
  if (!xs || xs.length === 0) return null
  const s = [...xs].sort((a, b) => a - b)
  return s[Math.floor(s.length / 2)]
}
const cut = (s, n) => {
  s = String(s || '').replace(/\s+/g, ' ').trim()
  return s.length > n ? `${s.slice(0, n - 1)}…` : s
}
const base = p => String(p || '').replace(/^.*[\\/]/, '')
const host = u => { try { return new URL(u).host } catch { return cut(u, 40) } }

// What kind of step this is: a history key, a category (for colour), a label and a detail line.
const describe = (tool, input) => {
  const i = input || {}
  if (tool === 'Bash' || tool === 'PowerShell') {
    const cmd = String(i.command || '').trim()
    const word = (cmd.split(/\s+/)[0] || 'command').replace(/^.*[\\/]/, '').toLowerCase()
    const isRender = RENDER.test(cmd)
    return {
      key: `${tool}:${word}${isRender ? ':render' : ''}`,
      cat: isRender ? 'render' : 'run',
      label: isRender ? `Rendering (${word})` : `Running ${word}`,
      detail: cut(i.description || cmd, 70),
    }
  }
  // Steps from regular Claude chats (sent by chat-watch.ps1), e.g. "Searching the web".
  if (tool === 'ClaudeChat') {
    const d = String(i.description || 'Working')
    const cat = /search|web|fetch|brows/i.test(d) ? 'web'
      : /image|design|render|video|draw|artifact/i.test(d) ? 'render'
      : /writ|edit|creat|draft|updat/i.test(d) ? 'edit'
      : /read|file|look/i.test(d) ? 'read'
      : /command|code|run|analy|calculat/i.test(d) ? 'run' : 'other'
    return { key: `chat:${cut(d, 40).toLowerCase()}`, cat, label: cut(d, 46), detail: '' }
  }
  const table = {
    Read: ['read', 'Reading', base(i.file_path)],
    Grep: ['read', 'Searching code', i.pattern],
    Glob: ['read', 'Finding files', i.pattern],
    Write: ['edit', 'Writing', base(i.file_path)],
    Edit: ['edit', 'Editing', base(i.file_path)],
    NotebookEdit: ['edit', 'Editing notebook', base(i.notebook_path)],
    WebSearch: ['web', 'Searching the web', i.query],
    WebFetch: ['web', 'Reading web page', host(i.url)],
    Agent: ['agent', 'Helper agent', i.description],
    Task: ['agent', 'Helper agent', i.description],
    Skill: ['other', 'Loading skill', i.skill],
  }
  if (table[tool]) {
    const [cat, label, detail] = table[tool]
    return { key: tool, cat, label, detail: cut(detail, 70) }
  }
  const short = String(tool).replace(/^mcp__[^_]+(__)?/, '').replace(/_/g, ' ')
  const firstText = Object.values(i).find(v => typeof v === 'string') || ''
  const isRender = /image|video|render|export|generate|design/i.test(short)
  const isWeb = /browser|navigate|fetch|page|screenshot/i.test(short)
  return {
    key: tool,
    cat: isRender ? 'render' : isWeb ? 'web' : 'other',
    label: isRender ? `Rendering: ${short}` : cut(short, 40),
    detail: cut(firstText, 70),
  }
}

const main = event => {
  let raw = ''
  try { raw = fs.readFileSync(0, 'utf8') } catch {}
  let e = {}
  try { e = JSON.parse(raw || '{}') } catch {}
  const failed = event === 'fail' || e.hook_event_name === 'PostToolUseFailure'
  if (event === 'fail') event = 'post'

  fs.mkdirSync(DIR, { recursive: true })
  const now = Date.now()
  const state = readJson(STATE, { sessions: {} })
  const history = readJson(HISTORY, {})
  const sid = e.session_id || 'default'
  const TURN = e.turn_key || 'turn' // chats learn their reply times apart from Claude Code jobs
  const s = state.sessions[sid] || { turnStartedAt: null, turnEstimateMs: null, steps: {}, log: [] }
  s.steps = s.steps || {}
  s.log = s.log || []
  s.cwd = e.cwd || s.cwd
  s.updatedAt = now

  const remember = (key, ms) => {
    if (ms < 300) return
    history[key] = [...(history[key] || []), ms].slice(-KEEP)
  }
  const startTurn = () => {
    s.turnStartedAt = now
    s.turnEstimateMs = median(history[TURN])
    s.steps = {}
    s.log = []
    s.finishedAt = null
  }
  const finishStep = (id, step) => {
    remember(step.key, now - step.startedAt)
    s.log.push({ ...step, endedAt: now, ok: !failed })
    s.log = s.log.slice(-LOG_MAX)
    delete s.steps[id]
  }

  if (event === 'prompt') {
    startTurn()
    if (e.prompt) s.title = cut(e.prompt, 60)
  } else if (event === 'pre') {
    if (!s.turnStartedAt) startTurn()
    const d = describe(e.tool_name, e.tool_input)
    const id = e.tool_use_id || `${d.key}-${now}`
    s.steps[id] = { ...d, startedAt: now, estimateMs: median(history[d.key]) }
  } else if (event === 'post') {
    const id = e.tool_use_id
    if (id && s.steps[id]) {
      finishStep(id, s.steps[id])
    } else {
      // No id match: close the oldest running step of the same kind.
      const { key } = describe(e.tool_name, e.tool_input)
      const found = Object.entries(s.steps).find(([, v]) => v.key === key)
      if (found) finishStep(found[0], found[1])
    }
  } else if (event === 'stop') {
    if (s.turnStartedAt) {
      s.lastTurnMs = now - s.turnStartedAt
      s.lastTurnStartedAt = s.turnStartedAt
      remember(TURN, s.lastTurnMs)
    }
    for (const [id, step] of Object.entries(s.steps)) finishStep(id, step)
    s.turnStartedAt = null
    s.finishedAt = now
  }

  state.sessions[sid] = s
  // Forget sessions untouched for a day.
  for (const [k, v] of Object.entries(state.sessions)) if (now - (v.updatedAt || 0) > 86400000) delete state.sessions[k]
  state.updatedAt = now
  writeJson(STATE, state)
  writeJson(HISTORY, history)
}

// Several chats can fire hooks at the same moment: take a short lock so their
// read-modify-write of state.json never overwrites each other.
const LOCK = path.join(DIR, 'state.lock')
const sleep = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
const withLock = fn => {
  try { fs.mkdirSync(DIR, { recursive: true }) } catch {}
  const deadline = Date.now() + 3000
  let fd = null
  while (fd === null) {
    try { fd = fs.openSync(LOCK, 'wx') } catch {
      try { if (Date.now() - fs.statSync(LOCK).mtimeMs > 3000) fs.unlinkSync(LOCK) } catch {}
      if (Date.now() > deadline) break // give up waiting; better a lost update than a stuck Claude
      sleep(15)
    }
  }
  try { fn() } finally {
    if (fd !== null) { try { fs.closeSync(fd); fs.unlinkSync(LOCK) } catch {} }
  }
}

try { withLock(() => main(process.argv[2])) } catch {}
process.exit(0)
