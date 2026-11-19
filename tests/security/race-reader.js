// Runs the window's exact read (Get-Content -Raw -Encoding UTF8 | ConvertFrom-Json) in a loop while
// hook.js fires 60 events, all in a temp CLAUDE_PROGRESS_DIR. Counts hook writes lost to the
// rename failing (EPERM) because the reader has state.json open without FILE_SHARE_DELETE.
const fs = require('fs'), path = require('path'), os = require('os')
const { spawnSync, spawn } = require('child_process')
const HOOK = path.join(__dirname, '..', '..', 'hook.js')
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-race-'))
const env = { ...process.env, CLAUDE_PROGRESS_DIR: dir }
const sf = path.join(dir, 'state.json')
const hook = (ev, p) => spawnSync(process.execPath, [HOOK, ev], { input: JSON.stringify(p), env })
hook('prompt', { session_id: 's', prompt: 'p' })
// argv[2]: 'old' = Get-Content (original window read), default 'new' = Read-State's FileShare ReadWrite,Delete read
const mode = process.argv[2] || 'new'
const read = mode === 'old'
  ? `$null = Get-Content '${sf}' -Raw -Encoding UTF8 | ConvertFrom-Json`
  : `$fs=[IO.File]::Open('${sf}','Open','Read',[IO.FileShare]'ReadWrite, Delete'); try { $t=(New-Object IO.StreamReader($fs,[Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }; $null = $t | ConvertFrom-Json`
console.log('reader mode:', mode)
const reader = spawn('powershell.exe', ['-NoProfile', '-Command',
  `$n=0; $end=(Get-Date).AddSeconds(25); while((Get-Date) -lt $end){ try { ${read}; $n++ } catch {} }; "reads=$n"`], { stdio: ['ignore', 'pipe', 'ignore'] })
setTimeout(() => {
  let lost = 0
  for (let i = 0; i < 60; i++) {
    const before = fs.readFileSync(sf, 'utf8')
    hook('pre', { session_id: 's', tool_name: 'Read', tool_input: { file_path: `f${i}` }, tool_use_id: `t${i}` })
    let st; try { st = JSON.parse(fs.readFileSync(sf, 'utf8')) } catch { st = null }
    if (!st || !st.sessions.s.steps[`t${i}`]) lost++
  }
  console.log(`hook writes lost while window-style reader runs: ${lost}/60; leftover .tmp files: ${fs.readdirSync(dir).filter(f => f.endsWith('.tmp')).length}`)
  reader.kill()
}, 1500)
