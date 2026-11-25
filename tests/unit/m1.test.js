// Milestone 1: the local job log, and an installer that changes nothing unless you say Yes.
const { test } = require('node:test')
const assert = require('node:assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const ROOT = path.join(__dirname, '..', '..')
const HOOK = path.join(ROOT, 'hook.js')
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'cp-m1-'))
const send = (dir, event, payload) => spawnSync(process.execPath, [HOOK, event], {
  input: JSON.stringify({ session_id: 'S', ...payload }),
  env: { ...process.env, CLAUDE_PROGRESS_DIR: dir }, encoding: 'utf8',
})
const jobs = dir => {
  const f = path.join(dir, 'jobs.jsonl')
  return fs.existsSync(f) ? fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []
}

test('each finished job adds one line to jobs.jsonl with its timing and size', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'Refactor the parser 😀', cwd: 'C:\\Projects\\my-app' })
  send(d, 'pre', { tool_name: 'Read', tool_use_id: 'r', tool_input: { file_path: 'a.js' } })
  send(d, 'post', { tool_name: 'Read', tool_use_id: 'r' })
  send(d, 'stop', {})
  const j = jobs(d)
  assert.strictEqual(j.length, 1)
  assert.strictEqual(j[0].project, 'my-app')
  assert.strictEqual(j[0].promptChars, 21, 'counted by characters, emoji = 1')
  assert.strictEqual(j[0].kind, 'code')
  assert.strictEqual(j[0].steps, 1)
  assert.ok(j[0].ms >= 0 && j[0].endedAt >= j[0].startedAt)
})

test('the job log never contains the prompt text or full paths', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'my secret plan for the launch', cwd: 'C:\\Users\\someone\\private\\proj' })
  send(d, 'stop', {})
  const raw = fs.readFileSync(path.join(d, 'jobs.jsonl'), 'utf8')
  assert.ok(!raw.includes('secret'), 'no prompt text')
  assert.ok(!raw.includes('someone'), 'no full path')
})

test('chats are logged as chat jobs, and a job waiting on helpers is logged once, when it really ends', () => {
  const d = tmp()
  send(d, 'prompt', { session_id: 'chat:hello', prompt: 'hello', cwd: 'Claude chat' })
  send(d, 'stop', { session_id: 'chat:hello' })
  assert.strictEqual(jobs(d)[0].kind, 'chat')
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'pre', { tool_name: 'Agent', tool_use_id: 'A', tool_input: { description: 'x', subagent_type: 'Explore' } })
  send(d, 'agent-start', { agent_id: 'ag', agent_type: 'Explore' })
  send(d, 'stop', {})
  assert.strictEqual(jobs(d).length, 1, 'not logged while the helper still works')
  send(d, 'agent-stop', { agent_id: 'ag', agent_type: 'Explore' })
  const j = jobs(d)
  assert.strictEqual(j.length, 2); assert.strictEqual(j[1].helpers, 1)
})

test('a big job log is rotated, not grown forever', () => {
  const d = tmp()
  fs.writeFileSync(path.join(d, 'jobs.jsonl'), 'x'.repeat(2 * 1024 * 1024 + 10))
  send(d, 'prompt', { prompt: 'go' }); send(d, 'stop', {})
  assert.ok(fs.existsSync(path.join(d, 'jobs.old.jsonl')))
  assert.strictEqual(jobs(d).length, 1)
})

// The installer is only run up to its question here: answering No (or nothing) must change nothing.
for (const answer of ['n', '', 'maybe']) {
  test(`installer: answering "${answer}" cancels and changes nothing`, { skip: process.platform !== 'win32' }, () => {
    const home = tmp()
    const r = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'install.ps1')], {
      // Every profile folder points into temp, so even a broken answer check could not touch the real ones.
      input: answer + '\r\n', env: { ...process.env, USERPROFILE: home, APPDATA: path.join(home, 'AppData', 'Roaming'), LOCALAPPDATA: path.join(home, 'AppData', 'Local') }, encoding: 'utf8', timeout: 60000,
    })
    assert.strictEqual(r.status, 0, r.stderr)
    assert.match(r.stdout, /this install will:/)
    assert.match(r.stdout, /Add 10 hooks/)
    assert.match(r.stdout, /Nothing was changed/)
    // PowerShell itself creates AppDataRoaming in a new profile when it starts; nothing else may appear.
    assert.deepStrictEqual(fs.readdirSync(home).filter(n => n !== 'AppData'), [], 'the installer created nothing')
    assert.ok(!fs.existsSync(path.join(home, '.claude')), 'no Claude settings touched')
  })
}

test('a turn that starts without a prompt does not reuse the last prompt length', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'twenty-four characters!!' }); send(d, 'stop', {})
  send(d, 'pre', { tool_name: 'Read', tool_use_id: 'r', tool_input: {} }); send(d, 'stop', {})
  const j = jobs(d)
  assert.strictEqual(j[0].promptChars, 24); assert.strictEqual(j[1].promptChars, 0)
})

test("if the old job log can't be replaced, the log starts afresh instead of growing forever", () => {
  const d = tmp()
  fs.mkdirSync(path.join(d, 'jobs.old.jsonl')) // a folder in the way: the rename fails
  fs.writeFileSync(path.join(d, 'jobs.jsonl'), 'x'.repeat(2 * 1024 * 1024 + 10))
  send(d, 'prompt', { prompt: 'go' }); send(d, 'stop', {})
  assert.ok(fs.statSync(path.join(d, 'jobs.jsonl')).size < 1000)
  assert.strictEqual(jobs(d).length, 1)
})
