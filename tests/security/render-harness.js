// Renders crafted state.json files through ClaudeProgress.ps1's real code path, offscreen.
// It copies ClaudeProgress.ps1 to a temp dir with ONE change: in -Snapshot mode, instead of writing
// its built-in sample state, it copies the crafted file ($env:CP_CRAFTED) to the state path that
// Update-View reads. USERPROFILE points at a temp profile, so nothing real is read or written.
// Usage: node render-harness.js [caseName]
const fs = require('fs'), path = require('path'), os = require('os')
const { spawnSync } = require('child_process')
const SRC = path.join(__dirname, '..', '..', 'ClaudeProgress.ps1')
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-render-'))
const profile = path.join(work, 'profile'); fs.mkdirSync(profile)
const orig = fs.readFileSync(SRC, 'utf8')
const needle = '$fake | ConvertTo-Json -Depth 8 | Set-Content -Path $stateFile -Encoding utf8'
if (!orig.includes(needle)) throw new Error('snapshot line not found; update the harness')
const patched = path.join(work, 'ClaudeProgress.ps1')
fs.writeFileSync(patched, (orig.startsWith('\uFEFF') ? '' : '\uFEFF') + orig.replace(needle, 'Copy-Item -LiteralPath $env:CP_CRAFTED -Destination $stateFile -Force'))

const now = Date.now()
const sess = (o = {}) => ({ cwd: 'C:\\p\\proj', title: 't', updatedAt: now, turnStartedAt: now - 20000, turnEstimateMs: 40000,
  steps: { a: { cat: 'run', label: 'Running x', detail: 'd', startedAt: now - 5000, estimateMs: 8000 } },
  log: [{ cat: 'read', label: 'Reading', detail: 'f', startedAt: now - 15000, endedAt: now - 12000, ok: true }], ...o })
const evil = '<TextBlock xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Text="{Binding}"/>{0}{1}{2}{99}$(Start-Process calc)`$env:USERNAME&amp;&lt;\'"\u202Eexe.txt\u0000\u0007\r\n\uD83D\u200F'
const long = 'W'.repeat(200000)
const cases = {
  hostile_text: { sessions: { [evil]: sess({ cwd: 'C:\\' + evil, title: evil + long,
    steps: { [evil]: { cat: evil, label: evil + long, detail: evil + long, startedAt: now - 5000, estimateMs: 2000 } },
    log: [{ cat: '__proto__', label: evil, detail: long, startedAt: now - 15000, endedAt: now - 12000, ok: false }] }) } },
  case_collision: { sessions: { 'chat:Foo': sess({ title: 'Foo' }), 'chat:foo': sess({ title: 'foo', turnStartedAt: null, finishedAt: now - 1000, lastTurnStartedAt: now - 9000 }) } },
  type_confusion: { sessions: { x: sess({ steps: [1, 2], log: 'str', turnStartedAt: 'abc', updatedAt: 'zzz' }), y: sess({ steps: { a: null }, log: [null, 5, 'x'] }) } },
  many_sessions: { sessions: Object.fromEntries(Array.from({ length: 400 }, (_, i) => [`s${i}`, sess({ title: `job ${i}`,
    log: Array.from({ length: 60 }, (_, j) => ({ cat: 'read', label: 'Reading', detail: `f${j}`, startedAt: now - 19000 + j * 10, endedAt: now - 19000 + j * 10 + 5, ok: true })) })])) },
  huge_file: { sessions: { big: sess({ title: 'big' }) }, pad: 'x'.repeat(30 * 1024 * 1024) },
  deep_nesting: JSON.parse('{"sessions":{"d":' + '{"a":'.repeat(2000) + '1' + '}'.repeat(2000) + '}}'),
}
const only = process.argv[2]
for (const [name, st] of Object.entries(cases)) {
  if (only && name !== only) continue
  const crafted = path.join(work, `${name}.json`)
  fs.writeFileSync(crafted, JSON.stringify(st))
  const out = path.join(work, `out-${name}`)
  const t = Date.now()
  const r = spawnSync('powershell.exe', ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', patched, '-Snapshot', out],
    { env: { ...process.env, USERPROFILE: profile, CP_CRAFTED: crafted }, encoding: 'utf8', timeout: 300000 })
  const errLog = path.join(profile, '.claude-progress', 'window-errors.log')
  const errs = fs.existsSync(errLog) ? fs.readFileSync(errLog, 'utf8').trim() : ''
  if (fs.existsSync(errLog)) fs.unlinkSync(errLog)
  const pngs = fs.existsSync(out) ? fs.readdirSync(out).filter(f => f.endsWith('.png')) : []
  console.log(`[${name}] ${(fs.statSync(crafted).size / 1024).toFixed(0)} KB, ${Date.now() - t} ms, exit=${r.status}${r.error ? ' ' + r.error.code : ''}, pngs=${pngs.length}`)
  if (errs) console.log('   window-errors.log:', errs.split('\n').slice(0, 3).join(' | '))
  const stderr = (r.stderr || '').trim(); if (stderr) console.log('   stderr:', stderr.split('\n').slice(0, 4).join(' | '))
}
console.log('work dir:', work)
