// Regression tests for bugs found by the QA / pen-test gates. Each runs hook.js or
// settings-hooks.js as a child process in a fresh temp folder (never the real profile).
const { test } = require('node:test')
const assert = require('node:assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const ROOT = path.join(__dirname, '..', '..')
const HOOK = path.join(ROOT, 'hook.js')
const SETTINGS = path.join(ROOT, 'settings-hooks.js')
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'cp-reg-'))
const run = (dir, event, payload) => spawnSync(process.execPath, [HOOK, event], {
  input: typeof payload === 'string' ? payload : JSON.stringify(payload),
  env: { ...process.env, CLAUDE_PROGRESS_DIR: dir }, encoding: 'utf8',
})
const state = dir => JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8'))

test('chat names that differ only in case share one session', () => {
  const d = tmp()
  run(d, 'prompt', { session_id: 'chat:Fix Bug', prompt: 'Fix Bug' })
  run(d, 'prompt', { session_id: 'chat:fix bug', prompt: 'fix bug' })
  assert.deepStrictEqual(Object.keys(state(d).sessions), ['chat:fix bug'])
})

test('old mixed-case chat keys are folded on upgrade, newest wins', () => {
  const d = tmp()
  const now = Date.now()
  fs.writeFileSync(path.join(d, 'state.json'), JSON.stringify({ sessions: {
    'chat:Fix Bug': { title: 'old', updatedAt: now - 5000, steps: {}, log: [] },
    'chat:FIX BUG': { title: 'newer', updatedAt: now - 1000, steps: {}, log: [] },
  } }))
  run(d, 'pre', { session_id: 'other', tool_name: 'Read', tool_input: {}, tool_use_id: 't' })
  const s = state(d).sessions
  assert.deepStrictEqual(Object.keys(s).filter(k => k.startsWith('chat:')), ['chat:fix bug'])
  assert.strictEqual(s['chat:fix bug'].title, 'newer')
})

test('Claude Code session ids keep their case', () => {
  const d = tmp()
  run(d, 'prompt', { session_id: 'ABC-123', prompt: 'x' })
  assert.ok(state(d).sessions['ABC-123'])
})

test('reserved object names as ids are stored safely, not dropped', () => {
  const d = tmp()
  for (const sid of ['__proto__', 'constructor', 'toString']) {
    run(d, 'pre', { session_id: sid, tool_name: 'constructor', tool_input: {}, tool_use_id: '__proto__' })
  }
  const s = state(d).sessions
  assert.deepStrictEqual(Object.keys(s).sort(), ['___proto__', '_constructor', '_toString'])
  assert.strictEqual(Object.keys(s._constructor.steps)[0], '___proto__')
})

test('titles lose bidi/control characters and are cut by whole characters', () => {
  const d = tmp()
  const prompt = 'invoice\u202Etxt.exe\u0007 ' + 'a'.repeat(57) + '😀😀'
  run(d, 'prompt', { session_id: 's', prompt })
  const title = state(d).sessions.s.title
  assert.ok(!/[\u202A-\u202E\u2066-\u2069\u0000-\u001F]/.test(title), 'no bidi or control chars')
  assert.ok(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(title), 'no lone surrogate')
  assert.ok(Array.from(title).length <= 60)
})

test('a directory squatting on state.lock is removed, not waited on', () => {
  const d = tmp()
  fs.mkdirSync(path.join(d, 'state.lock'))
  const t0 = Date.now()
  run(d, 'prompt', { session_id: 's', prompt: 'x' })
  assert.ok(Date.now() - t0 < 2000, 'took ' + (Date.now() - t0) + ' ms')
  assert.strictEqual(state(d).sessions.s.title, 'x')
})

test('valid JSON of the wrong shape is repaired', () => {
  for (const bad of ['{}', 'null', '[]', '{"sessions":null}', '{"sessions":[]}']) {
    const d = tmp()
    fs.writeFileSync(path.join(d, 'state.json'), bad)
    fs.writeFileSync(path.join(d, 'history.json'), '{"turn":"oops"}')
    run(d, 'prompt', { session_id: 's', prompt: 'x' })
    assert.strictEqual(state(d).sessions.s.title, 'x', 'for ' + bad)
  }
})

test('MCP labels drop the whole server name, even with underscores', () => {
  const d = tmp()
  const cases = { mcp__claude_in_chrome__navigate: 'navigate', mcp__plugin_marketing_figma__use_figma: 'use figma', mcp__ccd_session__mark_chapter: 'mark chapter', mcp__solo: 'solo' }
  for (const [tool, label] of Object.entries(cases)) {
    run(d, 'pre', { session_id: tool, tool_name: tool, tool_input: { a: 'b' }, tool_use_id: 't' })
    assert.strictEqual(state(d).sessions[tool].steps.t.label, label)
  }
})

test('no temp files are left behind after many writes', () => {
  const d = tmp()
  for (let i = 0; i < 10; i++) run(d, 'pre', { session_id: 's', tool_name: 'Read', tool_input: {}, tool_use_id: 't' + i })
  assert.deepStrictEqual(fs.readdirSync(d).filter(f => f.endsWith('.tmp')), [])
})

test('settings-hooks refuses paths a shell would expand', () => {
  const home = tmp()
  for (const bad of ['C:/a$HOME/node.exe', 'C:/a`id`/node.exe', 'C:/a%PATH%/node.exe']) {
    const r = spawnSync(process.execPath, [SETTINGS, 'add', bad, 'C:/x/hook.js'], { env: { ...process.env, USERPROFILE: home, HOME: home }, encoding: 'utf8' })
    assert.strictEqual(r.status, 1, bad)
    assert.match(r.stderr, /Can't install/)
  }
  assert.ok(!fs.existsSync(path.join(home, '.claude', 'settings.json')) || !fs.readFileSync(path.join(home, '.claude', 'settings.json'), 'utf8').includes('claude-progress-hook'))
})
