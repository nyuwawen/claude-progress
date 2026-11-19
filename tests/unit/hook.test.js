// Unit tests for hook.js, driven as a child process (the real interface).
// Every run sets CLAUDE_PROGRESS_DIR to a fresh temp dir, so ensureWindow() never launches anything.
const { test, describe, beforeEach, afterEach } = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync, spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const HOOK = path.resolve(__dirname, '..', '..', 'hook.js')
let dir

const env = () => ({ ...process.env, CLAUDE_PROGRESS_DIR: dir })
const run = (event, payload) => {
  const input = typeof payload === 'string' ? payload : JSON.stringify(payload ?? {})
  const args = event === undefined ? [HOOK] : [HOOK, event]
  const r = spawnSync(process.execPath, args, { input, env: env(), encoding: 'utf8', timeout: 15000 })
  assert.equal(r.status, 0, `exit code for ${event}: ${r.stderr}`)
  assert.equal(r.stdout, '', 'hook must print nothing on stdout')
  assert.equal(r.stderr, '', 'hook must print nothing on stderr')
  return r
}
const runAsync = (event, payload) => new Promise(resolve => {
  const p = spawn(process.execPath, [HOOK, event], { env: env(), stdio: ['pipe', 'pipe', 'pipe'] })
  let out = ''
  p.stdout.on('data', d => { out += d })
  p.stderr.on('data', d => { out += d })
  p.on('close', code => resolve({ code, out }))
  p.stdin.end(JSON.stringify(payload))
})
const stateFile = () => path.join(dir, 'state.json')
const historyFile = () => path.join(dir, 'history.json')
const readState = () => JSON.parse(fs.readFileSync(stateFile(), 'utf8'))
const readHistory = () => JSON.parse(fs.readFileSync(historyFile(), 'utf8'))
const writeState = s => fs.writeFileSync(stateFile(), JSON.stringify(s))
const writeHistory = h => fs.writeFileSync(historyFile(), JSON.stringify(h))
const sess = (id = 'S1') => readState().sessions[id]
const onlyStep = (id = 'S1') => {
  const steps = Object.values(sess(id).steps)
  assert.equal(steps.length, 1)
  return steps[0]
}
const pre = (tool_name, tool_input, extra = {}) =>
  run('pre', { session_id: 'S1', tool_name, tool_input, tool_use_id: 't1', ...extra })

beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-hook-')) })
afterEach(() => { fs.rmSync(dir, { recursive: true, force: true }) })

describe('process contract', () => {
  test('session event exits 0, prints nothing, writes no state and never creates the "alive" launcher file', () => {
    run('session', { session_id: 'S1' })
    assert.equal(fs.existsSync(stateFile()), false)
    assert.equal(fs.existsSync(path.join(dir, 'alive')), false)
  })

  test('ensureWindow does nothing when CLAUDE_PROGRESS_DIR is set (no alive file for any event)', () => {
    for (const ev of ['prompt', 'pre', 'post', 'stop']) run(ev, { session_id: 'S1', tool_name: 'Read', tool_use_id: 'x' })
    assert.equal(fs.existsSync(path.join(dir, 'alive')), false)
  })

  for (const [name, input] of [
    ['empty stdin', ''],
    ['non-JSON stdin', 'this is not json'],
    ['truncated JSON', '{"session_id":"S1","tool_name":'],
    ['JSON null', 'null'],
    ['JSON array', '[1,2,3]'],
    ['JSON number', '42'],
    ['BOM-prefixed JSON', '\uFEFF{"session_id":"S1"}'],
    ['binary garbage', '\u0000\u0001\u00ff\uFFFD'],
  ]) {
    for (const ev of ['prompt', 'pre', 'post', 'fail', 'stop', 'session', undefined, 'bogus']) {
      test(`exits 0 silently with ${name} on event ${ev}`, () => { run(ev, input) })
    }
  }

  test('malformed stdin falls back to the "default" session and still writes valid state', () => {
    run('prompt', 'garbage')
    const s = readState()
    assert.ok(s.sessions.default)
    assert.equal(typeof s.updatedAt, 'number')
    assert.deepEqual(readHistory(), {})
  })

  test('BOM-prefixed JSON payload is parsed (not treated as malformed)', () => {
    run('prompt', '﻿' + JSON.stringify({ session_id: 'BOM1', prompt: 'with bom' }))
    assert.equal(readState().sessions.BOM1?.title, 'with bom')
  })

  test('corrupt state.json / history.json are replaced instead of crashing', () => {
    fs.writeFileSync(stateFile(), '{not json')
    fs.writeFileSync(historyFile(), 'xx')
    run('prompt', { session_id: 'S1', prompt: 'hi' })
    assert.equal(sess().title, 'hi')
    assert.deepEqual(readHistory(), {})
  })

  // BUG (expected to fail): valid JSON of the wrong shape is not repaired like corrupt JSON is;
  // main() throws on state.sessions[sid], the error is swallowed, and state.json stays frozen forever.
  for (const shape of ['{}', '{"sessions":null}', '[]', 'null']) {
    test(`state.json with wrong shape ${shape} is repaired on the next event`, () => {
      fs.writeFileSync(stateFile(), shape)
      run('prompt', { session_id: 'S1', prompt: 'recovered' })
      assert.equal(readState().sessions?.S1?.title, 'recovered')
    })
  }

  test('no temp files or lock are left behind', () => {
    run('prompt', { session_id: 'S1' })
    pre('Read', { file_path: 'a.txt' })
    run('post', { session_id: 'S1', tool_name: 'Read', tool_use_id: 't1' })
    run('stop', { session_id: 'S1' })
    assert.deepEqual(fs.readdirSync(dir).sort(), ['history.json', 'state.json'])
  })
})

describe('turn lifecycle', () => {
  test('prompt starts a turn, sets title (cut to 60, whitespace collapsed) and cwd', () => {
    const before = Date.now()
    const long = 'Make   me\na ' + 'x'.repeat(100)
    run('prompt', { session_id: 'S1', prompt: long, cwd: 'C:\\proj' })
    const s = sess()
    assert.ok(s.turnStartedAt >= before && s.turnStartedAt <= Date.now())
    assert.equal(s.title.length, 60)
    assert.ok(s.title.startsWith('Make me a xxx'))
    assert.ok(s.title.endsWith('…'))
    assert.equal(s.cwd, 'C:\\proj')
    assert.deepEqual(s.steps, {})
    assert.deepEqual(s.log, [])
    assert.equal(s.finishedAt, null)
    assert.equal(s.turnEstimateMs, null)
  })

  test('prompt resets steps and log from the previous turn', () => {
    run('prompt', { session_id: 'S1' })
    pre('Read', { file_path: 'a' })
    run('post', { session_id: 'S1', tool_name: 'Read', tool_use_id: 't1' })
    pre('Read', { file_path: 'b' }, { tool_use_id: 't2' })
    run('prompt', { session_id: 'S1' })
    assert.deepEqual(sess().steps, {})
    assert.deepEqual(sess().log, [])
  })

  test('pre without a running turn auto-starts one', () => {
    pre('Read', { file_path: 'C:\\a\\b\\file.txt' })
    assert.equal(typeof sess().turnStartedAt, 'number')
    const st = onlyStep()
    assert.equal(st.key, 'Read')
    assert.equal(sess().steps.t1.detail, 'file.txt')
  })

  test('pre records step with startedAt and estimate = median of history for its key', () => {
    writeHistory({ Read: [500, 100, 900, 300, 700] })
    pre('Read', { file_path: 'x' })
    const st = sess().steps.t1
    assert.equal(st.estimateMs, 500)
    assert.equal(typeof st.startedAt, 'number')
  })

  test('pre without tool_use_id generates an id from key and time', () => {
    run('pre', { session_id: 'S1', tool_name: 'Grep', tool_input: { pattern: 'foo' } })
    const ids = Object.keys(sess().steps)
    assert.equal(ids.length, 1)
    assert.match(ids[0], /^Grep-\d+$/)
  })

  test('post with matching id moves step to log with ok=true and endedAt', () => {
    pre('Edit', { file_path: 'src/app.js' })
    run('post', { session_id: 'S1', tool_name: 'Edit', tool_use_id: 't1' })
    const s = sess()
    assert.deepEqual(s.steps, {})
    assert.equal(s.log.length, 1)
    assert.equal(s.log[0].ok, true)
    assert.equal(s.log[0].key, 'Edit')
    assert.equal(s.log[0].detail, 'app.js')
    assert.ok(s.log[0].endedAt >= s.log[0].startedAt)
  })

  test('fail event marks the step ok=false', () => {
    pre('Bash', { command: 'npm test' })
    run('fail', { session_id: 'S1', tool_name: 'Bash', tool_use_id: 't1' })
    assert.equal(sess().log[0].ok, false)
    assert.deepEqual(sess().steps, {})
  })

  test('post with hook_event_name PostToolUseFailure marks the step ok=false', () => {
    pre('Bash', { command: 'npm test' })
    run('post', { session_id: 'S1', tool_name: 'Bash', tool_use_id: 't1', hook_event_name: 'PostToolUseFailure' })
    assert.equal(sess().log[0].ok, false)
  })

  test('post with hook_event_name PostToolUse marks the step ok=true', () => {
    pre('Bash', { command: 'npm test' })
    run('post', { session_id: 'S1', tool_name: 'Bash', tool_use_id: 't1', hook_event_name: 'PostToolUse' })
    assert.equal(sess().log[0].ok, true)
  })

  test('post with unknown id closes the oldest running step of the same kind only', () => {
    run('prompt', { session_id: 'S1' })
    pre('Read', { file_path: 'a' }, { tool_use_id: 'r1' })
    pre('Grep', { pattern: 'p' }, { tool_use_id: 'g1' })
    pre('Read', { file_path: 'b' }, { tool_use_id: 'r2' })
    run('post', { session_id: 'S1', tool_name: 'Read', tool_use_id: 'nope' })
    const s = sess()
    assert.deepEqual(Object.keys(s.steps).sort(), ['g1', 'r2'])
    assert.equal(s.log.length, 1)
    assert.equal(s.log[0].detail, 'a')
  })

  test('post with no id and no matching step changes nothing in steps/log', () => {
    pre('Read', { file_path: 'a' })
    run('post', { session_id: 'S1', tool_name: 'Write', tool_input: { file_path: 'z' } })
    assert.deepEqual(Object.keys(sess().steps), ['t1'])
    assert.deepEqual(sess().log, [])
  })

  test('stop ends the turn, records lastTurnMs, closes running steps with ok=true', () => {
    run('prompt', { session_id: 'S1' })
    pre('Read', { file_path: 'a' })
    const startedAt = sess().turnStartedAt
    run('stop', { session_id: 'S1' })
    const s = sess()
    assert.equal(s.turnStartedAt, null)
    assert.equal(typeof s.finishedAt, 'number')
    assert.equal(s.lastTurnStartedAt, startedAt)
    assert.equal(s.lastTurnMs, s.finishedAt - startedAt)
    assert.deepEqual(s.steps, {})
    assert.equal(s.log.length, 1)
    assert.equal(s.log[0].ok, true)
  })

  test('stop without a running turn does not record a turn duration', () => {
    run('stop', { session_id: 'S1' })
    assert.equal(sess().lastTurnMs, undefined)
    assert.deepEqual(readHistory(), {})
  })

  test('sessions are kept apart by session_id', () => {
    run('prompt', { session_id: 'A', prompt: 'alpha' })
    run('prompt', { session_id: 'B', prompt: 'beta' })
    run('pre', { session_id: 'A', tool_name: 'Read', tool_input: {}, tool_use_id: 'a1' })
    const st = readState()
    assert.equal(st.sessions.A.title, 'alpha')
    assert.equal(st.sessions.B.title, 'beta')
    assert.deepEqual(Object.keys(st.sessions.A.steps), ['a1'])
    assert.deepEqual(st.sessions.B.steps, {})
  })

  test('missing session_id uses the "default" session', () => {
    run('prompt', { prompt: 'x' })
    assert.equal(readState().sessions.default.title, 'x')
  })

  test('cwd is kept when a later event omits it', () => {
    run('prompt', { session_id: 'S1', cwd: 'C:\\one' })
    pre('Read', {})
    assert.equal(sess().cwd, 'C:\\one')
  })

  test('unknown event only touches updatedAt (no turn started)', () => {
    run('bogus', { session_id: 'S1' })
    const s = sess()
    assert.equal(s.turnStartedAt, null)
    assert.equal(typeof s.updatedAt, 'number')
  })
})

describe('history', () => {
  const seedStep = (startedAt, key = 'Read') => writeState({
    sessions: { S1: { turnStartedAt: Date.now(), steps: { t1: { key, cat: 'read', label: 'Reading', detail: '', startedAt } }, log: [], updatedAt: Date.now() } },
  })

  test('step lasting >= 300 ms is remembered under its key', () => {
    seedStep(Date.now() - 5000)
    run('post', { session_id: 'S1', tool_name: 'Read', tool_use_id: 't1' })
    const h = readHistory()
    assert.equal(h.Read.length, 1)
    assert.ok(h.Read[0] >= 5000 && h.Read[0] < 20000, `got ${h.Read[0]}`)
  })

  test('step lasting < 300 ms is not remembered', () => {
    // startedAt slightly in the future so elapsed is far below 300 ms regardless of process start time.
    seedStep(Date.now() + 150)
    run('post', { session_id: 'S1', tool_name: 'Read', tool_use_id: 't1' })
    assert.equal(readHistory().Read, undefined)
    assert.equal(sess().log.length, 1, 'still logged even if not remembered')
  })

  test('back-to-back pre/post (real quick step) is not remembered', () => {
    pre('Glob', { pattern: '*.js' })
    const startedAt = sess().steps.t1.startedAt
    run('post', { session_id: 'S1', tool_name: 'Glob', tool_use_id: 't1' })
    const dur = sess().log[0].endedAt - startedAt
    const h = readHistory()
    if (dur < 300) assert.equal(h.Glob, undefined)
    else assert.equal(h.Glob.length, 1)
  })

  test('history keeps only the last 12 durations per key', () => {
    writeHistory({ Read: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] })
    seedStep(Date.now() - 5000)
    run('post', { session_id: 'S1', tool_name: 'Read', tool_use_id: 't1' })
    const h = readHistory().Read
    assert.equal(h.length, 12)
    assert.equal(h[0], 2)
    assert.ok(h[11] >= 5000)
  })

  test('turn duration goes to "turn" by default and sets turnEstimateMs from its median', () => {
    writeHistory({ turn: [1000, 3000, 2000], 'chat-turn': [9000] })
    run('prompt', { session_id: 'S1' })
    assert.equal(sess().turnEstimateMs, 2000)
    writeState({ sessions: { S1: { turnStartedAt: Date.now() - 4000, steps: {}, log: [], updatedAt: Date.now() } } })
    run('stop', { session_id: 'S1' })
    const h = readHistory()
    assert.equal(h.turn.length, 4)
    assert.ok(h.turn[3] >= 4000)
    assert.deepEqual(h['chat-turn'], [9000])
  })

  test('turn_key "chat-turn" uses its own bucket for estimate and duration', () => {
    writeHistory({ turn: [1000], 'chat-turn': [7000, 5000, 6000] })
    run('prompt', { session_id: 'C1', turn_key: 'chat-turn' })
    assert.equal(readState().sessions.C1.turnEstimateMs, 6000)
    writeState({ sessions: { C1: { turnStartedAt: Date.now() - 4000, steps: {}, log: [], updatedAt: Date.now() } } })
    run('stop', { session_id: 'C1', turn_key: 'chat-turn' })
    const h = readHistory()
    assert.deepEqual(h.turn, [1000])
    assert.equal(h['chat-turn'].length, 4)
    assert.ok(h['chat-turn'][3] >= 4000)
  })

  test('median of an even-length list takes the upper middle', () => {
    writeHistory({ Read: [100, 400, 200, 300] })
    pre('Read', {})
    assert.equal(sess().steps.t1.estimateMs, 300)
  })
})

describe('retention', () => {
  test('log is capped at 60 entries (newest kept)', () => {
    const log = Array.from({ length: 60 }, (_, n) => ({ key: 'Read', n }))
    writeState({ sessions: { S1: { turnStartedAt: Date.now(), steps: { t1: { key: 'Edit', startedAt: Date.now() } }, log, updatedAt: Date.now() } } })
    run('post', { session_id: 'S1', tool_name: 'Edit', tool_use_id: 't1' })
    const l = sess().log
    assert.equal(l.length, 60)
    assert.equal(l[0].n, 1)
    assert.equal(l[59].key, 'Edit')
  })

  test('sessions untouched for over 24 h are dropped; newer ones kept', () => {
    const now = Date.now()
    writeState({
      sessions: {
        old: { steps: {}, log: [], updatedAt: now - 25 * 3600e3 },
        noStamp: { steps: {}, log: [] },
        recent: { steps: {}, log: [], updatedAt: now - 23 * 3600e3 },
      },
    })
    run('prompt', { session_id: 'S1' })
    assert.deepEqual(Object.keys(readState().sessions).sort(), ['S1', 'recent'])
  })
})

describe('describe(): labels and categories', () => {
  test('Bash ordinary command -> run category', () => {
    pre('Bash', { command: '  git status --short', description: 'Show status' })
    const st = onlyStep()
    assert.equal(st.key, 'Bash:git')
    assert.equal(st.cat, 'run')
    assert.equal(st.label, 'Running git')
    assert.equal(st.detail, 'Show status')
  })

  test('Bash command with a path strips directory and lowercases the program name', () => {
    pre('Bash', { command: 'C:\\Tools\\NPM.cmd install' })
    const st = onlyStep()
    assert.equal(st.key, 'Bash:npm.cmd')
    assert.equal(st.detail, 'C:\\Tools\\NPM.cmd install', 'detail falls back to the command')
  })

  test('Bash render command (ffmpeg) -> render category and :render key', () => {
    pre('Bash', { command: 'ffmpeg -i in.mp4 out.webm' })
    const st = onlyStep()
    assert.equal(st.key, 'Bash:ffmpeg:render')
    assert.equal(st.cat, 'render')
    assert.equal(st.label, 'Rendering (ffmpeg)')
  })

  test('PowerShell render detection is keyword-anywhere (npm run build)', () => {
    pre('PowerShell', { command: 'npm run build' })
    const st = onlyStep()
    assert.equal(st.key, 'PowerShell:npm:render')
    assert.equal(st.cat, 'render')
    assert.equal(st.label, 'Rendering (npm)')
  })

  for (const kw of ['render', 'blender', 'remotion', 'magick', 'export', 'puppeteer', 'playwright', 'convert', 'BUILD']) {
    test(`render keyword "${kw}" is detected`, () => {
      pre('Bash', { command: `tool ${kw} x` })
      assert.equal(onlyStep().cat, 'render')
    })
  }

  test('Bash with empty command -> "command"', () => {
    pre('Bash', {})
    const st = onlyStep()
    assert.equal(st.key, 'Bash:command')
    assert.equal(st.label, 'Running command')
  })

  test('long Bash detail is cut to 70 chars with an ellipsis', () => {
    pre('Bash', { command: 'echo ' + 'a'.repeat(200) })
    const d = onlyStep().detail
    assert.equal(d.length, 70)
    assert.ok(d.endsWith('…'))
  })

  const table = [
    ['Read', { file_path: 'C:/x/y/a.md' }, 'read', 'Reading', 'a.md'],
    ['Grep', { pattern: 'TODO' }, 'read', 'Searching code', 'TODO'],
    ['Glob', { pattern: '**/*.ts' }, 'read', 'Finding files', '**/*.ts'],
    ['Write', { file_path: '/home/u/new.txt' }, 'edit', 'Writing', 'new.txt'],
    ['Edit', { file_path: 'C:\\src\\main.js' }, 'edit', 'Editing', 'main.js'],
    ['NotebookEdit', { notebook_path: 'C:\\nb\\a.ipynb' }, 'edit', 'Editing notebook', 'a.ipynb'],
    ['WebSearch', { query: 'node test runner' }, 'web', 'Searching the web', 'node test runner'],
    ['WebFetch', { url: 'https://example.com/a/b?c=d' }, 'web', 'Reading web page', 'example.com'],
    ['WebFetch', { url: 'not a url' }, 'web', 'Reading web page', 'not a url'],
    ['Agent', { description: 'Find bugs' }, 'agent', 'Helper agent', 'Find bugs'],
    ['Task', { description: 'Sub task' }, 'agent', 'Helper agent', 'Sub task'],
    ['Skill', { skill: 'pdf' }, 'other', 'Loading skill', 'pdf'],
    ['Read', undefined, 'read', 'Reading', ''],
  ]
  for (const [tool, input, cat, label, detail] of table) {
    test(`table tool ${tool} ${JSON.stringify(input)} -> ${cat}/${label}/${detail}`, () => {
      pre(tool, input)
      const st = onlyStep()
      assert.deepEqual({ key: st.key, cat: st.cat, label: st.label, detail: st.detail }, { key: tool, cat, label, detail })
    })
  }

  test('MCP tool -> server prefix stripped, underscores to spaces, first string as detail', () => {
    pre('mcp__github__list_issues', { owner: 'acme', count: 3 })
    const st = onlyStep()
    assert.equal(st.key, 'mcp__github__list_issues')
    assert.equal(st.cat, 'other')
    assert.equal(st.label, 'list issues')
    assert.equal(st.detail, 'acme')
  })

  test('MCP render-ish tool -> render category, "Rendering:" label', () => {
    pre('mcp__figma__generate_image', { prompt: 'a cat' })
    const st = onlyStep()
    assert.equal(st.cat, 'render')
    assert.equal(st.label, 'Rendering: generate image')
    assert.equal(st.detail, 'a cat')
  })

  test('MCP browser tool -> web category', () => {
    pre('mcp__Claude_Browser__navigate', { url: 'https://x.y' })
    const st = onlyStep()
    assert.equal(st.cat, 'web')
  })

  test('MCP tool with a hyphenated server id', () => {
    pre('mcp__7d06bb89-7ca1-4ade__notion-search', { query: 'q' })
    const st = onlyStep()
    assert.equal(st.label, 'notion-search')
    assert.equal(st.cat, 'other')
  })

  // BUG (expected to fail): the prefix regex /^mcp__[^_]+(__)?/ stops at the first single "_",
  // so servers whose names contain underscores leak part of the server name into the label.
  for (const [tool, want] of [
    ['mcp__claude_in_chrome__navigate', 'navigate'],
    ['mcp__plugin_marketing_figma__use_figma', 'use figma'],
    ['mcp__ccd_session__mark_chapter', 'mark chapter'],
  ]) {
    test(`MCP server name containing underscores is fully stripped: ${tool} -> "${want}"`, () => {
      pre(tool, { x: 'y' })
      assert.equal(onlyStep().label, want)
    })
  }

  test('unknown non-MCP tool with no string inputs', () => {
    pre('SomeTool', { n: 1 })
    const st = onlyStep()
    assert.deepEqual({ key: st.key, cat: st.cat, label: st.label, detail: st.detail }, { key: 'SomeTool', cat: 'other', label: 'SomeTool', detail: '' })
  })

  const chat = [
    ['Searching the web', 'web'],
    ['Fetching page', 'web'],
    ['Browsing', 'web'],
    ['Creating image', 'render'],
    ['Making artifact', 'render'],
    ['Drawing a video', 'render'],
    ['Writing a draft', 'edit'],
    ['Updating document', 'edit'],
    ['Reading file', 'read'],
    ['Looking at it', 'read'],
    ['Running code', 'run'],
    ['Analyzing data', 'run'],
    ['Calculating', 'run'],
    ['Thinking', 'other'],
  ]
  for (const [d, cat] of chat) {
    test(`ClaudeChat "${d}" -> ${cat}`, () => {
      pre('ClaudeChat', { description: d })
      const st = onlyStep()
      assert.equal(st.cat, cat)
      assert.equal(st.label, d)
      assert.equal(st.key, `chat:${d.toLowerCase()}`)
      assert.equal(st.detail, '')
    })
  }

  test('ClaudeChat without description -> "Working"; long label cut to 46', () => {
    pre('ClaudeChat', {})
    assert.equal(onlyStep().label, 'Working')
    assert.equal(onlyStep().key, 'chat:working')
    pre('ClaudeChat', { description: 'Q'.repeat(100) }, { tool_use_id: 't2' })
    const st = sess().steps.t2
    assert.equal(st.label.length, 46)
    assert.equal(st.key.length, 'chat:'.length + 40)
  })

  test('chat flow: prompt/pre/post/stop with turn_key chat-turn', () => {
    const base = { session_id: 'chat-1', turn_key: 'chat-turn' }
    run('prompt', { ...base, prompt: 'hello chat' })
    run('pre', { ...base, tool_name: 'ClaudeChat', tool_input: { description: 'Searching the web' }, tool_use_id: 'c1' })
    run('post', { ...base, tool_name: 'ClaudeChat', tool_input: { description: 'Searching the web' }, tool_use_id: 'c1' })
    run('stop', base)
    const s = readState().sessions['chat-1']
    assert.equal(s.title, 'hello chat')
    assert.equal(s.log.length, 1)
    assert.equal(s.log[0].cat, 'web')
    assert.equal(s.turnStartedAt, null)
  })
})

describe('locking', () => {
  test('stale lock (older than 3 s) is broken and the update goes through', () => {
    const lock = path.join(dir, 'state.lock')
    fs.writeFileSync(lock, '')
    const old = new Date(Date.now() - 10000)
    fs.utimesSync(lock, old, old)
    const t = Date.now()
    run('prompt', { session_id: 'S1', prompt: 'after stale' })
    assert.ok(Date.now() - t < 2500, 'should not wait for the deadline')
    assert.equal(sess().title, 'after stale')
    assert.equal(fs.existsSync(lock), false)
  })

  test('a fresh lock that is never released: hook waits ~3 s then still exits 0', () => {
    const lock = path.join(dir, 'state.lock')
    fs.writeFileSync(lock, '')
    // mtime in the future so the lock never looks stale while the hook waits.
    const future = new Date(Date.now() + 60000)
    fs.utimesSync(lock, future, future)
    const t = Date.now()
    run('prompt', { session_id: 'S1', prompt: 'gave up waiting' })
    const took = Date.now() - t
    assert.ok(took >= 2500 && took < 10000, `took ${took} ms`)
    assert.equal(sess().title, 'gave up waiting', 'writes anyway after giving up')
    assert.equal(fs.existsSync(lock), true, 'does not delete a lock it does not own')
  })
})

describe('concurrency', () => {
  test('20 parallel pre events on one session: valid JSON, all 20 steps present', async () => {
    run('prompt', { session_id: 'S1', prompt: 'parallel' })
    const N = 20
    const res = await Promise.all(Array.from({ length: N }, (_, n) =>
      runAsync('pre', { session_id: 'S1', tool_name: 'Read', tool_input: { file_path: `f${n}.txt` }, tool_use_id: `id${n}` })))
    for (const r of res) { assert.equal(r.code, 0); assert.equal(r.out, '') }
    const s = readState().sessions.S1
    assert.equal(Object.keys(s.steps).length, N)
    for (let n = 0; n < N; n++) {
      const st = s.steps[`id${n}`]
      assert.ok(st, `step id${n} missing`)
      assert.equal(st.detail, `f${n}.txt`)
      assert.equal(st.key, 'Read')
    }
    assert.equal(s.title, 'parallel')
    assert.equal(fs.existsSync(path.join(dir, 'state.lock')), false)
  })

  test('20 parallel post events close every step into the log exactly once', async () => {
    run('prompt', { session_id: 'S1' })
    const N = 20
    await Promise.all(Array.from({ length: N }, (_, n) =>
      runAsync('pre', { session_id: 'S1', tool_name: 'Edit', tool_input: { file_path: `e${n}` }, tool_use_id: `id${n}` })))
    await Promise.all(Array.from({ length: N }, (_, n) =>
      runAsync(n % 2 ? 'fail' : 'post', { session_id: 'S1', tool_name: 'Edit', tool_use_id: `id${n}` })))
    const s = readState().sessions.S1
    assert.deepEqual(s.steps, {})
    assert.equal(s.log.length, N)
    const details = s.log.map(l => l.detail).sort()
    assert.deepEqual(details, Array.from({ length: N }, (_, n) => `e${n}`).sort())
    for (const l of s.log) assert.equal(l.ok, Number(l.detail.slice(1)) % 2 === 0)
    JSON.parse(fs.readFileSync(historyFile(), 'utf8'))
  })

  test('20 parallel events across 4 sessions keep every session and step', async () => {
    const N = 20
    await Promise.all(Array.from({ length: N }, (_, n) =>
      runAsync('pre', { session_id: `S${n % 4}`, tool_name: 'Grep', tool_input: { pattern: `p${n}` }, tool_use_id: `g${n}` })))
    const st = readState()
    assert.deepEqual(Object.keys(st.sessions).sort(), ['S0', 'S1', 'S2', 'S3'])
    const total = Object.values(st.sessions).reduce((a, s) => a + Object.keys(s.steps).length, 0)
    assert.equal(total, N)
    const leftovers = fs.readdirSync(dir).filter(f => f.endsWith('.tmp') || f === 'state.lock')
    assert.deepEqual(leftovers, [])
  })
})
