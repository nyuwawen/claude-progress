// Runs settings-hooks.js add with USERPROFILE/HOME pointed at a temp profile (never the real one)
// and checks that paths with shell-expanded characters are refused and normal ones accepted.
const fs = require('fs'), path = require('path'), os = require('os')
const { spawnSync } = require('child_process')
const SH = path.join(__dirname, '..', '..', 'settings-hooks.js')
const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-prof-'))
const env = { ...process.env, USERPROFILE: prof, HOME: prof }
for (const home of ['C:\\Users\\alice', 'C:\\Users\\jo$HOME', 'C:\\Users\\a`id`b', 'C:\\Users\\a%PATH%b', 'C:\\Users\\a!b', "C:\\Users\\o'brien", 'C:\\Users\\a&b', 'C:\\Users\\a;b']) {
  const r = spawnSync(process.execPath, [SH, 'add', 'C:\\Program Files\\nodejs\\node.exe', `${home}\\.claude-progress\\app\\hook.js`], { env, encoding: 'utf8' })
  const f = path.join(prof, '.claude', 'settings.json')
  const written = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')).hooks?.PreToolUse?.[0]?.hooks?.[0]?.command : null
  console.log(home.padEnd(22), 'exit', r.status, r.status ? (r.stderr.trim()) : '=> ' + written)
  fs.rmSync(path.join(prof, '.claude'), { recursive: true, force: true })
}
fs.rmSync(prof, { recursive: true, force: true })
