// Feeds crafted events to hook.js with CLAUDE_PROGRESS_DIR = a temp dir (this also disables its
// task launch). Usage: node hook-fuzz.js  -> prints results; leaves the temp dir path for inspection.
const fs = require('fs'), path = require('path'), os = require('os')
const { spawnSync, spawn } = require('child_process')
const HOOK = path.join(__dirname, '..', '..', 'hook.js')
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-fuzz-'))
const env = { ...process.env, CLAUDE_PROGRESS_DIR: dir }
const run = (ev, payload, extra = {}) => {
  const t = Date.now()
  const r = spawnSync(process.execPath, [HOOK, ev], { input: typeof payload === 'string' ? payload : JSON.stringify(payload), env, encoding: 'utf8', timeout: 20000, ...extra })
  return { ms: Date.now() - t, code: r.status, out: (r.stdout || '') + (r.stderr || '') }
}
const state = () => { try { return JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8')) } catch (e) { return 'ERR ' + e.message } }
const reset = () => { for (const f of fs.readdirSync(dir)) fs.rmSync(path.join(dir, f), { recursive: true, force: true }) }
const log = (...a) => console.log(...a)

// 1. prototype-ish session ids
for (const sid of ['__proto__', 'constructor', 'toString', 'hasOwnProperty']) {
  reset()
  const r1 = run('prompt', { session_id: sid, cwd: 'C:\\x', prompt: 'hello' })
  const r2 = run('pre', { session_id: sid, tool_name: 'Read', tool_input: { file_path: 'a.txt' }, tool_use_id: 't1' })
  const st = state()
  log(`[sid=${sid}] exit=${r1.code},${r2.code} out=${JSON.stringify(r1.out + r2.out)} sessions keys=${typeof st === 'string' ? st : JSON.stringify(Object.keys(st.sessions))}`)
}
// tool names / ids that collide with Object.prototype in history / steps
for (const tool of ['constructor', '__proto__', 'toString']) {
  reset()
  run('prompt', { session_id: 's', prompt: 'p' })
  const r = run('pre', { session_id: 's', tool_name: tool, tool_input: { x: 'y' }, tool_use_id: 'id1' })
  const st = state()
  log(`[tool=${tool}] exit=${r.code} steps=${typeof st === 'string' ? st : JSON.stringify(Object.keys(st.sessions.s.steps))}`)
}
for (const id of ['__proto__', 'constructor']) {
  reset()
  run('prompt', { session_id: 's', prompt: 'p' })
  run('pre', { session_id: 's', tool_name: 'Read', tool_input: { file_path: 'a' }, tool_use_id: id })
  const st = state()
  log(`[tool_use_id=${id}] steps=${JSON.stringify(Object.keys(st.sessions.s.steps))}`)
}

// 2. hostile strings survive into state.json as plain data
reset()
const nasty = '<Window xmlns="x"/>{0}{1}$(calc)`n&amp;\'"\u202Eevil\u0000\u0007\r\n' + 'A'.repeat(56) + '\u{1F600}tail'
run('prompt', { session_id: 'n', cwd: 'C:\\' + nasty, prompt: nasty })
run('pre', { session_id: 'n', tool_name: 'Bash', tool_input: { command: nasty, description: nasty }, tool_use_id: 'b1' })
const sn = state().sessions.n
log('[nasty] title=', JSON.stringify(sn.title), 'len', sn.title.length, '| cwd len', sn.cwd.length, '| detail=', JSON.stringify(sn.steps.b1.detail))
// emoji split at the cut boundary
reset()
run('prompt', { session_id: 'e', prompt: 'x'.repeat(58) + '\u{1F600}\u{1F600}' })
log('[surrogate split] title tail codes=', [...state().sessions.e.title.slice(-3)].map(c => c.codePointAt(0).toString(16)).join(','))

// 3. huge stdin (10 MB prompt)
reset()
let r = run('prompt', { session_id: 'big', prompt: 'x'.repeat(10 * 1024 * 1024) })
log('[10MB prompt] ms=', r.ms, 'exit', r.code, 'state size', fs.statSync(path.join(dir, 'state.json')).size)
// malformed stdin
r = run('prompt', '{not json')
log('[malformed stdin] exit', r.code, 'sessions', JSON.stringify(Object.keys(state().sessions)))
// malformed state.json on disk
fs.writeFileSync(path.join(dir, 'state.json'), '[]')
r = run('prompt', { session_id: 'z', prompt: 'p' })
log('[state.json = []] exit', r.code, 'state now', JSON.stringify(state()).slice(0, 80))
fs.writeFileSync(path.join(dir, 'state.json'), '{"sessions":null}')
r = run('prompt', { session_id: 'z', prompt: 'p' })
log('[state.json sessions:null] exit', r.code, 'state now', JSON.stringify(state()).slice(0, 80))

// 4. state.lock as a directory -> every hook call waits the full 3 s deadline
reset()
fs.mkdirSync(path.join(dir, 'state.lock'))
fs.utimesSync(path.join(dir, 'state.lock'), new Date(0), new Date(0))
r = run('pre', { session_id: 'l', tool_name: 'Read', tool_input: {}, tool_use_id: 'x' })
log('[state.lock is a dir] ms=', r.ms, 'exit', r.code)
reset()
fs.writeFileSync(path.join(dir, 'state.lock'), '')
r = run('pre', { session_id: 'l', tool_name: 'Read', tool_input: {}, tool_use_id: 'x' })
log('[fresh stale state.lock file] ms=', r.ms)
// stdin never closed: does the hook hang? (Claude Code's 10 s hook timeout would then fire)
reset()
{
  const t = Date.now()
  const c = spawn(process.execPath, [HOOK, 'pre'], { env, stdio: ['pipe', 'ignore', 'ignore'] })
  c.stdin.write('{"session_id":"open"}')
  const kill = setTimeout(() => { c.kill(); log('[stdin left open] still running after 4 s -> waits for EOF (killed)') ; next() }, 4000)
  c.on('exit', () => { clearTimeout(kill); log('[stdin left open] exited in', Date.now() - t, 'ms') ; next() })
}

// 5. state.json held open by a reader (like the window's Get-Content) while the hook renames over it
function next() {
  reset()
  run('prompt', { session_id: 'r', prompt: 'p' })
  const sf = path.join(dir, 'state.json')
  const holder = spawn('powershell.exe', ['-NoProfile', '-Command',
    `$f=[IO.File]::Open('${sf}','Open','Read','ReadWrite'); 'held'; Start-Sleep -Seconds 4; $f.Close()`], { stdio: ['ignore', 'pipe', 'ignore'] })
  holder.stdout.once('data', () => {
    const r = run('stop', { session_id: 'r' })
    const st = state()
    log('[rename while state.json open for read] exit', r.code, 'finishedAt set?', !!st.sessions.r.finishedAt,
      '| leftover tmp files:', fs.readdirSync(dir).filter(f => f.endsWith('.tmp')))
    holder.kill()
    log('temp dir:', dir)
  })
}
