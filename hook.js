// Claude Progress - hook script.
// Claude Code runs this on: UserPromptSubmit (turn starts), PreToolUse (step starts),
// PostToolUse / PostToolUseFailure (step ends), SubagentStart / SubagentStop (a helper agent
// starts / finishes) and Stop (turn ends). It reads the event
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
const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
// Write to a temp file, then swap it in. The window may be reading the file at that instant
// (Windows then refuses the rename), so retry briefly, and never leave temp files behind.
const writeJson = (file, value) => {
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value))
  for (let i = 0; ; i++) {
    try { fs.renameSync(tmp, file); return } catch (err) {
      if (i >= 20 || !['EPERM', 'EBUSY', 'EACCES'].includes(err.code)) { try { fs.unlinkSync(tmp) } catch {} throw err }
      pause(25)
    }
  }
}
const median = xs => {
  if (!Array.isArray(xs) || xs.length === 0) return null
  const s = [...xs].sort((a, b) => a - b)
  return s[Math.floor(s.length / 2)]
}
// Display text: no control or text-direction characters (they can make a title read
// differently from what it is), whitespace collapsed, cut by whole characters (never half an emoji).
const cut = (s, n) => {
  s = String(s || '').replace(/[‪-‮⁦-⁩‎‏]/g, '').replace(/[\s\p{Cc}]+/gu, ' ').trim()
  const chars = Array.from(s)
  return chars.length > n ? `${chars.slice(0, n - 1).join('')}…` : s
}
// Keys taken from input must never be special object names.
const safeKey = k => (k === '__proto__' || k in Object.prototype) ? `_${k}` : k
// What a helper agent is doing, for the window's Team view. Its type decides first
// ("UI Finish-Gate Reviewer" is checking, even though it is about UI), then its task.
const ROLES = [
  ['review', /review|check|verif|audit|gate|\bqa\b|critic|inspect|align|approv|guardian/i],
  ['test', /test|secur|pen.?test|fuzz/i],
  ['design', /design|\bui\b|\bux\b|visual|brand|layout|mock.?up|figma|image|creative|whims|illustrat|story/i],
  ['plan', /plan|architect|strateg/i],
  ['research', /explor|research|search|find|investig|look|guide|fetch|analy|read|scan/i],
  ['write', /writ|content|copy|\bdoc|draft/i],
  ['build', /build|implement|code|fix|develop|engineer|refactor|migrat|install|make|creat/i],
]
const roleOf = (type, task) => {
  const hit = ROLES.find(([, re]) => re.test(type)) || ROLES.find(([, re]) => re.test(task))
  return hit ? hit[0] : 'other'
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
  if (Object.hasOwn(table, tool)) { // own keys only: a tool named "constructor" is not in the table
    const [cat, label, detail] = table[tool]
    return { key: tool, cat, label, detail: cut(detail, 70) }
  }
  // mcp__<server>__<tool>: server names may contain single underscores (claude_in_chrome).
  const short = String(tool).replace(/^mcp__(.+?__)?/, '').replace(/_/g, ' ')
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
  raw = raw.replace(/^﻿/, '') // PowerShell pipes can start with a byte-order mark
  try { e = JSON.parse(raw || '{}') } catch {}
  const failed = event === 'fail' || e.hook_event_name === 'PostToolUseFailure'
  if (event === 'fail') event = 'post'

  fs.mkdirSync(DIR, { recursive: true })
  const now = Date.now()
  // Valid JSON of the wrong shape (e.g. {} or null after an outside edit) is replaced, not trusted.
  const isObj = v => v !== null && typeof v === 'object' && !Array.isArray(v)
  let state = readJson(STATE, null)
  if (!isObj(state) || !isObj(state.sessions)) state = { sessions: {} }
  // Older versions kept chat keys in their original case; fold them to lower case
  // (if two clash, keep the most recently updated one).
  for (const k of Object.keys(state.sessions)) {
    const low = k.toLowerCase()
    if (!k.startsWith('chat:') || k === low) continue
    const v = state.sessions[k]; delete state.sessions[k]
    const cur = state.sessions[low]
    if (!cur || (Number(v && v.updatedAt) || 0) > (Number(cur && cur.updatedAt) || 0)) state.sessions[low] = v
  }
  let history = readJson(HISTORY, null)
  if (!isObj(history)) history = {}
  // Chat names are matched without regard to case ("Fix Bug" and "fix bug" are one chat): the
  // window's JSON reader can't hold two keys that differ only in case.
  let sid = String(e.session_id || 'default')
  if (sid.startsWith('chat:')) sid = sid.toLowerCase()
  sid = safeKey(sid)
  const TURN = safeKey(String(e.turn_key || 'turn')) // chats learn their reply times apart from Claude Code jobs
  const s = state.sessions[sid] || { turnStartedAt: null, turnEstimateMs: null, steps: {}, log: [] }
  if (!isObj(s.steps)) s.steps = {}
  if (!Array.isArray(s.log)) s.log = []
  s.cwd = e.cwd || s.cwd
  s.updatedAt = now

  const remember = (key, ms) => {
    if (ms < 300) return
    key = safeKey(key)
    history[key] = [...(Array.isArray(history[key]) ? history[key] : []), ms].slice(-KEEP)
  }
  // Helper agents (subagents). A helper's own row carries `agent` (its id) and stays open until
  // SubagentStop, even when it runs in the background and its Agent tool call returned at once.
  // Steps the helper itself runs carry `by` (its id). A helper silent for 2 hours is forgotten.
  const isHelper = v => isObj(v) && typeof v.agent === 'string'
  for (const [id, v] of Object.entries(s.steps)) {
    if (!isObj(v) || (v.agent || v.by) && now - (Number(v.startedAt) || 0) > 7200000) delete s.steps[id]
  }
  const helpersLeft = () => Object.values(s.steps).some(isHelper)
  const agentId = e.agent_id ? String(e.agent_id) : null
  const agentType = cut(e.agent_type || 'helper', 30)

  const startTurn = () => {
    s.turnStartedAt = now
    s.turnEstimateMs = median(history[TURN])
    // Helpers still working from the last turn keep going (with their steps), and while the team
    // is still at work its finished helpers stay listed too (a helper's report starts a new turn).
    s.steps = Object.fromEntries(Object.entries(s.steps).filter(([, v]) => v.agent || v.by))
    // The same holds just after the last helper finished (Claude is now reading its report).
    const teamRecent = now - (Number(s.teamDoneAt) || 0) < 120000
    s.log = helpersLeft() || teamRecent ? s.log.filter(l => isObj(l) && l.agent) : []
    s.teamDoneAt = null
    s.finishedAt = null
    s.waiting = false
  }
  const finishStep = (id, step) => {
    // Count a helper's steps on the helper itself: its own steps may fall out of the log
    // (a new turn starts while it keeps working).
    if (step.by) { const h = Object.values(s.steps).find(v => isHelper(v) && v.agent === step.by); if (h) h.done = (Number(h.done) || 0) + 1 }
    remember(step.key, now - step.startedAt)
    s.log.push({ ...step, endedAt: now, ok: !failed })
    s.log = s.log.slice(-LOG_MAX)
    delete s.steps[id]
  }
  const endTurn = () => {
    if (s.turnStartedAt) {
      s.lastTurnMs = now - s.turnStartedAt
      s.lastTurnStartedAt = s.turnStartedAt
      remember(TURN, s.lastTurnMs)
    }
    for (const [id, step] of Object.entries(s.steps)) finishStep(id, step)
    s.turnStartedAt = null
    s.finishedAt = now
    s.waiting = false
  }

  if (event === 'prompt') {
    startTurn()
    if (e.prompt) s.title = cut(e.prompt, 60)
  } else if (event === 'pre') {
    if (!s.turnStartedAt) startTurn()
    const d = describe(e.tool_name, e.tool_input)
    const id = safeKey(String(e.tool_use_id || `${d.key}-${now}`))
    const step = { ...d, startedAt: now, estimateMs: median(history[safeKey(d.key)]) }
    if (agentId) { step.by = agentId; step.label = cut(`${agentType} › ${d.label}`, 60) }
    if (d.cat === 'agent' && isObj(e.tool_input)) step.wants = String(e.tool_input.subagent_type || '')
    s.steps[id] = step
  } else if (event === 'post') {
    const id = e.tool_use_id ? safeKey(String(e.tool_use_id)) : null
    if (id && Object.hasOwn(s.steps, id)) {
      // A helper's Agent call returns at once when it runs in the background: keep its row open.
      if (!isHelper(s.steps[id])) finishStep(id, s.steps[id])
    } else {
      // No id match: close the oldest running step of the same kind. Never a helper's row, and not
      // for an Agent call: a finished helper's call would otherwise close another helper's.
      const { key, cat } = describe(e.tool_name, e.tool_input)
      if (cat === 'agent') return save()
      const found = Object.entries(s.steps).find(([, v]) => v.key === key && !isHelper(v) && (v.by || null) === agentId)
      if (found) finishStep(found[0], found[1])
    }
  } else if (event === 'agent-start' && agentId && e.agent_type) { // no type: Claude's own internal agents
    if (!s.turnStartedAt) startTurn()
    const label = `Helper agent (${agentType})`
    // Claim the Agent call that launched it (same type first, then any unclaimed one).
    const calls = Object.entries(s.steps).filter(([, v]) => v.cat === 'agent' && !v.agent && !v.by)
    const mine = calls.find(([, v]) => v.wants && v.wants.toLowerCase() === agentType.toLowerCase()) || calls.find(([, v]) => !v.wants) || calls[0]
    const task = mine ? String(mine[1].detail || '') : ''
    const who = { who: agentType, role: roleOf(agentType, task) }
    if (mine) Object.assign(mine[1], { agent: agentId, label, ...who })
    else s.steps[safeKey(`agent-${agentId}`)] = { key: `agent:${agentType}`, cat: 'agent', label, detail: '', startedAt: now, estimateMs: null, agent: agentId, ...who }
  } else if (event === 'agent-stop' && agentId) {
    for (const [id, v] of Object.entries(s.steps)) if (v.agent === agentId || v.by === agentId) finishStep(id, v)
    if (!helpersLeft()) s.teamDoneAt = now
    if (s.waiting && !helpersLeft()) endTurn()
  } else if (event === 'stop') {
    // The reply is done, but background helpers may still be working: the job ends when they do.
    if (helpersLeft()) {
      for (const [id, step] of Object.entries(s.steps)) if (!step.agent && !step.by) finishStep(id, step)
      s.waiting = true
    } else endTurn()
  }

  save()
  function save() {
    state.sessions[sid] = s
    // Forget sessions untouched for a day.
    for (const [k, v] of Object.entries(state.sessions)) if (now - (v.updatedAt || 0) > 86400000) delete state.sessions[k]
    state.updatedAt = now
    writeJson(STATE, state)
    writeJson(HISTORY, history)
  }
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
      try {
        const st = fs.statSync(LOCK)
        if (st.isDirectory()) fs.rmSync(LOCK, { recursive: true, force: true }) // not ours: a lock is always a file
        else if (Date.now() - st.mtimeMs > 3000) fs.unlinkSync(LOCK)
      } catch {}
      if (Date.now() > deadline) break // give up waiting; better a lost update than a stuck Claude
      sleep(15)
    }
  }
  try { fn() } finally {
    if (fd !== null) { try { fs.closeSync(fd); fs.unlinkSync(LOCK) } catch {} }
  }
}

// Opens the window if it isn't running. The window touches "alive" every few seconds; if that's
// stale, start it through Task Scheduler (so it belongs to Windows, not to Claude, and keeps
// running when Claude closes).
const ensureWindow = () => {
  if (process.env.CLAUDE_PROGRESS_DIR) return // demo
  const alive = path.join(DIR, 'alive')
  let age = Infinity
  try { age = Date.now() - fs.statSync(alive).mtimeMs } catch {}
  if (age < 20000) return
  try { fs.mkdirSync(DIR, { recursive: true }); fs.writeFileSync(alive, '') } catch {} // no double launch while it starts
  try {
    const { spawn } = require('child_process')
    spawn('schtasks.exe', ['/run', '/tn', 'Claude Progress'], { detached: true, stdio: 'ignore', windowsHide: true }).unref()
  } catch {}
}

const event = process.argv[2]
try { ensureWindow() } catch {}
if (event !== 'session') { try { withLock(() => main(event)) } catch {} }
setTimeout(() => process.exit(0), 50) // let the launcher start before exiting
