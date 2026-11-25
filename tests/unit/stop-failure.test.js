// StopFailure: a turn that ends on an API error (rate limit, server error...) instead of a reply.
// hook.js runs as a child process in a fresh temp folder, as in the other tests.
const { test } = require('node:test')
const assert = require('node:assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const HOOK = path.join(__dirname, '..', '..', 'hook.js')
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'cp-stopfail-'))
const send = (dir, event, payload = {}) => spawnSync(process.execPath, [HOOK, event], {
  input: JSON.stringify({ session_id: 'S', ...payload }),
  env: { ...process.env, CLAUDE_PROGRESS_DIR: dir }, encoding: 'utf8',
})
const sess = dir => JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8')).sessions.S
const jobs = dir => fs.readFileSync(path.join(dir, 'jobs.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l))

test('a turn that ends on an error ends the job and says which error', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'pre', { tool_name: 'Bash', tool_use_id: 'b1', tool_input: { command: 'npm test' } })
  const r = send(d, 'stop-error', { hook_event_name: 'StopFailure', error: 'rate_limit', error_details: '429 Too Many Requests' })
  assert.strictEqual(r.status, 0)
  const s = sess(d)
  assert.strictEqual(s.turnStartedAt, null, 'the job is over (no card stuck on "Working")')
  assert.ok(s.finishedAt > 0)
  assert.strictEqual(s.endedOn.error, 'rate_limit')
  assert.strictEqual(Object.keys(s.steps).length, 0, 'the open step was closed')
  assert.strictEqual(jobs(d).length, 1, 'logged like any finished job')
})

test('a normal stop clears an earlier error, and so does the next job', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'stop-error', { error: 'server_error' })
  assert.ok(sess(d).endedOn)
  send(d, 'prompt', { prompt: 'again' })
  assert.strictEqual(sess(d).endedOn, null, 'a new job starts clean')
  send(d, 'stop')
  assert.strictEqual(sess(d).endedOn, null, 'a reply that finished is not an error')
})

test('an error with no job running records nothing, and a missing or odd error type is kept short', () => {
  const d = tmp()
  send(d, 'session')
  send(d, 'stop-error', { error: 'rate_limit' })
  assert.ok(!sess(d).endedOn)
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'stop-error', {})
  assert.strictEqual(sess(d).endedOn.error, 'unknown')
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'stop-error', { error: 'x'.repeat(500) })
  assert.ok(sess(d).endedOn.error.length <= 41)
})

test('a stray stop with no job running leaves the last job\'s finish time alone', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'stop')
  const fin = sess(d).finishedAt
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 30)
  send(d, 'stop-error', { error: 'server_error' })
  send(d, 'stop')
  assert.strictEqual(sess(d).finishedAt, fin, 'an old job must not look just finished (it would notify again)')
})

test('background helpers still working: the job waits for them, the error is kept', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'pre', { tool_name: 'Agent', tool_use_id: 'A1', tool_input: { description: 'look', subagent_type: 'Explore', prompt: 'p' } })
  send(d, 'agent-start', { agent_id: 'ag-1', agent_type: 'Explore' })
  send(d, 'stop-error', { error: 'server_error' })
  let s = sess(d)
  assert.ok(s.turnStartedAt, 'still running while the helper works')
  assert.strictEqual(s.endedOn.error, 'server_error')
  send(d, 'agent-stop', { agent_id: 'ag-1', agent_type: 'Explore' })
  s = sess(d)
  assert.strictEqual(s.turnStartedAt, null)
  assert.strictEqual(s.endedOn.error, 'server_error')
})
