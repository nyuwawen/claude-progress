// "Needs you": Claude stops mid-job to ask for permission. hook.js runs as a child process in a fresh
// temp folder, as in the other tests.
const { test } = require('node:test')
const assert = require('node:assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const HOOK = path.join(__dirname, '..', '..', 'hook.js')
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'cp-need-'))
const send = (dir, event, payload = {}) => spawnSync(process.execPath, [HOOK, event], {
  input: JSON.stringify({ session_id: 'S', ...payload }),
  env: { ...process.env, CLAUDE_PROGRESS_DIR: dir }, encoding: 'utf8',
})
const sess = dir => JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8')).sessions.S
const history = dir => JSON.parse(fs.readFileSync(path.join(dir, 'history.json'), 'utf8'))
const jobs = dir => fs.readFileSync(path.join(dir, 'jobs.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l))
const wait = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
const permission = { hook_event_name: 'Notification', notification_type: 'permission_prompt', message: 'Claude needs your permission to use Bash' }

test('a permission prompt during a job marks the chat as needing you, with the message', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'pre', { tool_name: 'Bash', tool_use_id: 'b1', tool_input: { command: 'rm -rf build' } })
  send(d, 'notify', permission)
  const s = sess(d)
  assert.ok(s.needsYou, 'needsYou is set')
  assert.strictEqual(s.needsYou.message, 'Claude needs your permission to use Bash')
  assert.ok(Number(s.needsYou.since) > 0)
})

test('the next event ends the wait, and the waited time is kept out of the step and the job', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'pre', { tool_name: 'Bash', tool_use_id: 'b1', tool_input: { command: 'npm test' } })
  send(d, 'notify', permission)
  wait(700)
  send(d, 'post', { tool_name: 'Bash', tool_use_id: 'b1', tool_input: { command: 'npm test' } })
  const s = sess(d)
  assert.strictEqual(s.needsYou, null, 'the wait ended')
  assert.ok(s.pausedMs >= 600, `job paused time recorded (${s.pausedMs})`)
  // The step took about 700ms of wall time, nearly all of it waiting: under 300ms it is not learned.
  const learned = Object.entries(history(d)).filter(([k]) => k !== 'turn')
  assert.strictEqual(learned.length, 0, 'waiting for you is not learned as step time')
  send(d, 'stop')
  const [job] = jobs(d)
  assert.ok(job.waitedMs >= 600, `jobs.jsonl keeps the wait apart (${job.waitedMs})`)
  assert.ok(job.ms < job.endedAt - job.startedAt, 'ms is working time, without the wait')
})

test('"waiting for your input" after a reply is not a blocked job', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'stop')
  send(d, 'notify', { hook_event_name: 'Notification', notification_type: 'idle_prompt', message: 'Claude is waiting for your input' })
  assert.ok(!sess(d).needsYou)
})

test('an idle prompt during a job is ignored too; only permission or a question counts', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'notify', { hook_event_name: 'Notification', notification_type: 'idle_prompt', message: 'Claude is waiting for your input' })
  assert.ok(!sess(d).needsYou)
  send(d, 'notify', { hook_event_name: 'Notification', notification_type: 'elicitation_dialog', message: 'Claude has a question' })
  assert.ok(sess(d).needsYou, 'a question to you counts')
})

test('older versions without notification_type: the message decides', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'notify', { hook_event_name: 'Notification', message: 'Claude is waiting for your input' })
  assert.ok(!sess(d).needsYou)
  send(d, 'notify', { hook_event_name: 'Notification', message: 'Claude needs your permission to use Write' })
  assert.ok(sess(d).needsYou)
})

test('a second prompt while already waiting keeps the first time', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'notify', permission)
  const first = sess(d).needsYou.since
  wait(50)
  send(d, 'notify', permission)
  assert.strictEqual(sess(d).needsYou.since, first)
})

test('a new job starts with no wait and no paused time', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'notify', permission)
  send(d, 'prompt', { prompt: 'again' })
  const s = sess(d)
  assert.ok(!s.needsYou)
  assert.strictEqual(s.pausedMs, 0)
})

test("a background helper's steps don't end a wait that Claude itself is in", () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'pre', { tool_name: 'Agent', tool_use_id: 'A1', tool_input: { description: 'look', subagent_type: 'Explore', prompt: 'p' } })
  send(d, 'agent-start', { agent_id: 'ag-1', agent_type: 'Explore' })
  send(d, 'post', { tool_name: 'Agent', tool_use_id: 'A1', tool_input: {}, tool_response: { status: 'async_launched' } })
  send(d, 'pre', { tool_name: 'Bash', tool_use_id: 'b1', tool_input: { command: 'deploy' } })   // Claude's own step
  send(d, 'notify', permission)
  send(d, 'pre', { tool_name: 'Grep', tool_use_id: 'g1', tool_input: { pattern: 'x' }, agent_id: 'ag-1', agent_type: 'Explore' })
  assert.ok(sess(d).needsYou, 'still waiting for you')
  send(d, 'post', { tool_name: 'Bash', tool_use_id: 'b1', tool_input: { command: 'deploy' } })
  assert.ok(!sess(d).needsYou, "Claude's own step ends the wait")
})

test("with nothing of Claude's own open, a helper's next step ends the wait (the prompt was the helper's)", () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'pre', { tool_name: 'Agent', tool_use_id: 'A1', tool_input: { description: 'look', subagent_type: 'Explore', prompt: 'p' } })
  send(d, 'agent-start', { agent_id: 'ag-1', agent_type: 'Explore' })
  send(d, 'notify', permission)
  send(d, 'pre', { tool_name: 'Grep', tool_use_id: 'g1', tool_input: { pattern: 'x' }, agent_id: 'ag-1', agent_type: 'Explore' })
  assert.ok(!sess(d).needsYou)
})