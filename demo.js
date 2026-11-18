// Claude Progress - demo. Plays two fake Claude chats at the same time through hook.js,
// into a separate demo folder, so your real timing history is never touched.
//   Chat 1 renders a video; the render runs past its estimate twice (watch the bar re-estimate).
//   Chat 2 fixes a form; one test run fails, then passes.
// Usage: node demo.js <path to hook.js>   (CLAUDE_PROGRESS_DIR must point at the demo folder)

const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')

const hook = process.argv[2] || path.join(__dirname, 'hook.js')
const dir = process.env.CLAUDE_PROGRESS_DIR
if (!dir) { console.error('Set CLAUDE_PROGRESS_DIR to the demo folder'); process.exit(1) }

fs.mkdirSync(dir, { recursive: true })
try { fs.unlinkSync(path.join(dir, 'state.json')) } catch {}
// Pretend earlier jobs happened, so the demo has estimates to show.
fs.writeFileSync(path.join(dir, 'history.json'), JSON.stringify({
  turn: [38000, 42000, 40000],
  Read: [1200, 1500],
  Grep: [1500],
  Edit: [1800, 2200],
  Write: [1500],
  'Bash:ffmpeg:render': [12000, 14000, 13000],
}))

const wait = ms => new Promise(r => setTimeout(r, ms))
const chat = (session_id, cwd) => {
  let n = 0
  const send = (event, payload = {}) =>
    execFileSync(process.execPath, [hook, event], { input: JSON.stringify({ session_id, cwd, ...payload }), env: process.env })
  const step = async (tool_name, tool_input, ms, failed = false) => {
    const tool_use_id = `${session_id}-${++n}`
    send('pre', { tool_name, tool_input, tool_use_id })
    await wait(ms)
    send(failed ? 'fail' : 'post', { tool_name, tool_input, tool_use_id })
  }
  return { send, step }
}

const video = async () => {
  const c = chat('demo-video', 'C:\\Projects\\video-project')
  c.send('prompt', { prompt: 'Render the product intro video in 4K' })
  await wait(1500)
  await c.step('Read', { file_path: 'C:\\Projects\\video-project\\timeline.json' }, 1500)
  await wait(2000) // thinking
  await c.step('Bash', { command: 'ffmpeg -framerate 60 -i frames/%04d.png -c:v libx264 intro-4k.mp4', description: 'Render frames into intro-4k.mp4' }, 24000)
  await c.step('Write', { file_path: 'C:\\Projects\\video-project\\RENDER-NOTES.md' }, 1500)
  await wait(2500) // writing the reply
  c.send('stop')
}

const form = async () => {
  await wait(4000)
  const c = chat('demo-form', 'C:\\Projects\\website')
  c.send('prompt', { prompt: 'Fix the contact form validation' })
  await wait(1200)
  await c.step('Grep', { pattern: 'validateEmail' }, 1500)
  await c.step('Read', { file_path: 'C:\\Projects\\website\\src\\contact.js' }, 1000)
  await wait(1800) // thinking
  await c.step('Edit', { file_path: 'C:\\Projects\\website\\src\\contact.js' }, 2000)
  await c.step('Bash', { command: 'npm test', description: 'Run the test suite' }, 5000, true)
  await wait(1500)
  await c.step('Edit', { file_path: 'C:\\Projects\\website\\src\\contact.js' }, 1500)
  await c.step('Bash', { command: 'npm test', description: 'Run the test suite again' }, 4500)
  await wait(2000)
  c.send('stop')
}

Promise.all([video(), form()])
