// Claude Progress - adds or removes its hooks in ~/.claude/settings.json.
// node settings-hooks.js add <node.exe> <hook.js>
// node settings-hooks.js remove
// Only entries whose command mentions "claude-progress-hook" are touched; everything else is kept.

const fs = require('fs')
const path = require('path')
const os = require('os')

const MARK = 'claude-progress-hook'
const file = path.join(os.homedir(), '.claude', 'settings.json')
const [, , action, nodeExe, hookJs] = process.argv

let settings = {}
if (fs.existsSync(file)) {
  const text = fs.readFileSync(file, 'utf8')
  try { settings = JSON.parse(text) } catch {
    console.error(`Could not read ${file} (not valid JSON). Nothing was changed.`)
    process.exit(1)
  }
  fs.writeFileSync(`${file}.before-claude-progress.bak`, text)
}

const hooks = settings.hooks || {}
// Remove our old entries first, so add is safe to run twice.
for (const ev of Object.keys(hooks)) {
  hooks[ev] = hooks[ev]
    .map(group => ({ ...group, hooks: (group.hooks || []).filter(h => !String(h.command || '').includes(MARK)) }))
    .filter(group => group.hooks.length > 0)
  if (hooks[ev].length === 0) delete hooks[ev]
}

if (action === 'add') {
  // Hook commands may be run by a shell (cmd or bash): refuse paths with characters it would expand.
  for (const p of [nodeExe, hookJs]) {
    if (/[$`"!%]/.test(p)) { console.error(`Can't install from a path containing $ \` " ! or %: ${p}`); process.exit(1) }
  }
  const q = p => `"${p.replace(/\\/g, '/')}"`
  // The trailing "#claude-progress-hook" marks our entries; the hook ignores extra args.
  const cmd = ev => `${q(nodeExe)} ${q(hookJs)} ${ev} ${MARK}`
  const add = (ev, arg, matcher) => {
    const group = { hooks: [{ type: 'command', command: cmd(arg), timeout: 10 }] }
    if (matcher) group.matcher = matcher
    hooks[ev] = [...(hooks[ev] || []), group]
  }
  add('SessionStart', 'session') // opens the window as soon as a Claude session starts
  add('UserPromptSubmit', 'prompt')
  add('PreToolUse', 'pre', '*')
  add('PostToolUse', 'post', '*')
  add('PostToolUseFailure', 'post', '*')
  add('Stop', 'stop')
  add('StopFailure', 'stop-error') // the turn ended on an API error instead of a reply
  add('SubagentStart', 'agent-start') // a helper agent starts or finishes (also background ones)
  add('SubagentStop', 'agent-stop')
  add('Notification', 'notify') // Claude asks for your permission mid-job ("needs you")
}

if (Object.keys(hooks).length > 0) settings.hooks = hooks
else delete settings.hooks
fs.mkdirSync(path.dirname(file), { recursive: true })
fs.writeFileSync(file, JSON.stringify(settings, null, 2))
console.log(action === 'add' ? `Hooks added to ${file}` : `Hooks removed from ${file}`)
