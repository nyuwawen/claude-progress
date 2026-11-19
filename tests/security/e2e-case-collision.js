// Two Claude chats whose titles differ only in letter case ("Fix Bug" then later "fix bug") are sent
// by chat-watch.ps1 as session_id "chat:Fix Bug" / "chat:fix bug". hook.js (JS, case-sensitive)
// stores both. The window parses state.json with Windows PowerShell 5.1 ConvertFrom-Json, which
// rejects keys that differ only by case -> Update-View returns early on every tick (silently) and the
// window shows "idle" for every chat, Claude Code included, until the old session ages out (24 h).
const fs = require('fs'), path = require('path'), os = require('os')
const { spawnSync } = require('child_process')
const HOOK = path.join(__dirname, '..', '..', 'hook.js')
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-case-'))
const env = { ...process.env, CLAUDE_PROGRESS_DIR: dir }
const hook = (ev, p) => spawnSync(process.execPath, [HOOK, ev], { input: JSON.stringify(p), env })
// exactly what chat-watch.ps1 Start-Chat / Stop-Chat send
hook('prompt', { session_id: 'chat:Fix Bug', cwd: 'Claude chat', prompt: 'Fix Bug', turn_key: 'chat-turn' })
hook('stop', { session_id: 'chat:Fix Bug', cwd: 'Claude chat', turn_key: 'chat-turn' })
hook('prompt', { session_id: 'chat:fix bug', cwd: 'Claude chat', prompt: 'fix bug', turn_key: 'chat-turn' })
// a normal Claude Code session that is working right now
hook('prompt', { session_id: '6f1c2d3e-0000-4000-8000-000000000001', cwd: 'C:\\proj', prompt: 'refactor' })
const sf = path.join(dir, 'state.json')
console.log('sessions in state.json:', Object.keys(JSON.parse(fs.readFileSync(sf, 'utf8')).sessions))
// the window's exact parse (ClaudeProgress.ps1:886)
const r = spawnSync('powershell.exe', ['-NoProfile', '-Command',
  `try { $s = Get-Content '${sf}' -Raw -Encoding UTF8 | ConvertFrom-Json; 'parsed OK: ' + (@($s.sessions.PSObject.Properties).Count) + ' sessions' } catch { 'ConvertFrom-Json FAILED: ' + $_.Exception.Message }`], { encoding: 'utf8' })
console.log(r.stdout.trim())
