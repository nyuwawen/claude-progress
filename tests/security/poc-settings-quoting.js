// settings-hooks.js:34-36 wraps paths in double quotes. If Claude Code runs the hook command through
// a POSIX shell (Git Bash on Windows), "$..." and `...` inside a path are expanded. This builds the
// command exactly like settings-hooks.js and shows how bash would see the argv (printf, nothing run).
const { spawnSync } = require('child_process')
const MARK = 'claude-progress-hook'
const q = p => `"${p.replace(/\\/g, '/')}"`                        // verbatim
const cmd = (nodeExe, hookJs, ev) => `${q(nodeExe)} ${q(hookJs)} ${ev} ${MARK}` // verbatim
for (const home of ['C:\\Users\\alice', 'C:\\Users\\jo$HOME', 'C:\\Users\\a`id`b', "C:\\Users\\o'brien"]) {
  const c = cmd('C:\\Program Files\\nodejs\\node.exe', `${home}\\.claude-progress\\app\\hook.js`, 'pre')
  const r = spawnSync(process.env.BASH_EXE || 'C:\\Program Files\\Git\\bin\\bash.exe', ['-c', `printf '[%s] ' ${c.replace(/^"[^"]*"/, '')}`], { encoding: 'utf8' })
  console.log(c.padEnd(90), '=> bash argv:', (r.stdout || r.error?.code || r.stderr).trim())
}
