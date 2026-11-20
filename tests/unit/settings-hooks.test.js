// Unit tests for settings-hooks.js. USERPROFILE and HOME always point at a fresh temp dir,
// so the real ~/.claude/settings.json is never touched.
const { test, beforeEach, afterEach } = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const SCRIPT = path.resolve(__dirname, '..', '..', 'settings-hooks.js')
const NODE = 'C:\\Program Files\\nodejs\\node.exe'
const HOOK = 'C:\\Users\\me\\.claude-progress\\hook.js'
const MARK = 'claude-progress-hook'
const EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SubagentStart', 'SubagentStop']
let home, file

const run = (...args) => {
  const r = spawnSync(process.execPath, [SCRIPT, ...args], {
    env: { ...process.env, USERPROFILE: home, HOME: home },
    encoding: 'utf8',
    timeout: 15000,
  })
  return r
}
const read = () => JSON.parse(fs.readFileSync(file, 'utf8'))
const write = obj => {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2))
}
const ours = s => Object.entries(s.hooks || {}).flatMap(([ev, groups]) =>
  groups.flatMap(g => g.hooks.filter(h => String(h.command).includes(MARK)).map(h => ({ ev, g, h }))))

beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-home-'))
  file = path.join(home, '.claude', 'settings.json')
})
afterEach(() => { fs.rmSync(home, { recursive: true, force: true }) })

test('sandbox: script resolves settings.json inside the temp home', () => {
  const r = run('add', NODE, HOOK)
  assert.equal(r.status, 0, r.stderr)
  assert.ok(r.stdout.includes(file), `stdout: ${r.stdout}`)
  assert.ok(fs.existsSync(file))
})

test('add on a fresh profile creates settings.json with 8 marked hooks', () => {
  const r = run('add', NODE, HOOK)
  assert.equal(r.status, 0)
  assert.match(r.stdout, /Hooks added to/)
  const s = read()
  assert.deepEqual(Object.keys(s.hooks).sort(), [...EVENTS].sort())
  const mine = ours(s)
  assert.equal(mine.length, 8)
  const arg = { SessionStart: 'session', UserPromptSubmit: 'prompt', PreToolUse: 'pre', PostToolUse: 'post', PostToolUseFailure: 'post', Stop: 'stop', SubagentStart: 'agent-start', SubagentStop: 'agent-stop' }
  for (const { ev, g, h } of mine) {
    assert.equal(h.type, 'command')
    assert.equal(h.timeout, 10)
    assert.equal(h.command, `"C:/Program Files/nodejs/node.exe" "C:/Users/me/.claude-progress/hook.js" ${arg[ev]} ${MARK}`)
    if (['PreToolUse', 'PostToolUse', 'PostToolUseFailure'].includes(ev)) assert.equal(g.matcher, '*')
    else assert.equal(g.matcher, undefined)
  }
  assert.equal(fs.existsSync(`${file}.before-claude-progress.bak`), false, 'no backup when there was no file')
})

test('add is idempotent: running twice does not duplicate', () => {
  run('add', NODE, HOOK)
  const first = fs.readFileSync(file, 'utf8')
  const r = run('add', NODE, HOOK)
  assert.equal(r.status, 0)
  assert.equal(fs.readFileSync(file, 'utf8'), first)
  assert.equal(ours(read()).length, 8)
})

test('add with a new path replaces the old entries instead of adding more', () => {
  run('add', NODE, HOOK)
  run('add', 'D:\\node\\node.exe', 'D:\\cp\\hook.js')
  const mine = ours(read())
  assert.equal(mine.length, 8)
  for (const { h } of mine) assert.ok(h.command.startsWith('"D:/node/node.exe" "D:/cp/hook.js"'))
})

const userSettings = () => ({
  model: 'opus',
  permissions: { allow: ['Bash(git status)'] },
  env: { FOO: 'bar' },
  hooks: {
    PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'echo user-pre' }] }],
    Stop: [{ hooks: [{ type: 'command', command: 'notify.exe done', timeout: 5 }] }],
    Notification: [{ hooks: [{ type: 'command', command: 'beep' }] }],
  },
})

test('add keeps unrelated settings and user hooks', () => {
  write(userSettings())
  assert.equal(run('add', NODE, HOOK).status, 0)
  const s = read()
  const u = userSettings()
  assert.equal(s.model, 'opus')
  assert.deepEqual(s.permissions, u.permissions)
  assert.deepEqual(s.env, u.env)
  assert.deepEqual(s.hooks.Notification, u.hooks.Notification)
  assert.deepEqual(s.hooks.PreToolUse[0], u.hooks.PreToolUse[0])
  assert.equal(s.hooks.PreToolUse.length, 2)
  assert.deepEqual(s.hooks.Stop[0], u.hooks.Stop[0])
  assert.equal(ours(s).length, 8)
})

test('add writes a .bak with the exact previous text', () => {
  const text = JSON.stringify(userSettings(), null, 4) + '\n'
  write(text)
  run('add', NODE, HOOK)
  assert.equal(fs.readFileSync(`${file}.before-claude-progress.bak`, 'utf8'), text)
})

test('remove deletes only marked entries and restores the user settings', () => {
  write(userSettings())
  run('add', NODE, HOOK)
  const r = run('remove')
  assert.equal(r.status, 0)
  assert.match(r.stdout, /Hooks removed from/)
  assert.deepEqual(read(), userSettings())
})

test('remove keeps a non-marked hook that shares a group with a marked one', () => {
  write({ hooks: { Stop: [{ hooks: [
    { type: 'command', command: `node hook.js stop ${MARK}` },
    { type: 'command', command: 'echo keep-me' },
  ] }] } })
  run('remove')
  assert.deepEqual(read(), { hooks: { Stop: [{ hooks: [{ type: 'command', command: 'echo keep-me' }] }] } })
})

test('remove on settings with only our hooks drops the hooks key entirely', () => {
  write({ theme: 'dark' })
  run('add', NODE, HOOK)
  run('remove')
  assert.deepEqual(read(), { theme: 'dark' })
})

test('remove on a fresh profile exits 0 and leaves an empty settings object', () => {
  const r = run('remove')
  assert.equal(r.status, 0)
  assert.deepEqual(read(), {})
})

test('remove writes a .bak of the pre-remove file', () => {
  write(userSettings())
  run('add', NODE, HOOK)
  const before = fs.readFileSync(file, 'utf8')
  run('remove')
  assert.equal(fs.readFileSync(`${file}.before-claude-progress.bak`, 'utf8'), before)
})

for (const action of ['add', 'remove']) {
  test(`${action} refuses invalid JSON, exits 1 and does not change the file or write a .bak`, () => {
    const bad = '{ "model": "opus", // comment\n "hooks": { }'
    write(bad)
    const r = action === 'add' ? run('add', NODE, HOOK) : run('remove')
    assert.equal(r.status, 1)
    assert.match(r.stderr, /not valid JSON/)
    assert.equal(fs.readFileSync(file, 'utf8'), bad)
    assert.equal(fs.existsSync(`${file}.before-claude-progress.bak`), false)
  })
}

test('add -> remove -> add round trip leaves exactly 8 marked hooks', () => {
  write(userSettings())
  run('add', NODE, HOOK)
  run('remove')
  run('add', NODE, HOOK)
  const s = read()
  assert.equal(ours(s).length, 8)
  assert.equal(s.hooks.PreToolUse.length, 2)
  assert.equal(s.model, 'opus')
})
