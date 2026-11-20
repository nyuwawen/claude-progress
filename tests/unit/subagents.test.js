// Helper agents (subagents): hook.js runs as a child process in a fresh temp folder.
const { test } = require('node:test')
const assert = require('node:assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const HOOK = path.join(__dirname, '..', '..', 'hook.js')
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'cp-sub-'))
const send = (dir, event, payload) => spawnSync(process.execPath, [HOOK, event], {
  input: JSON.stringify({ session_id: 'S', ...payload }),
  env: { ...process.env, CLAUDE_PROGRESS_DIR: dir }, encoding: 'utf8',
})
const sess = dir => JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8')).sessions.S
const launch = (d, id, type, opts = {}) => {
  send(d, 'pre', { tool_name: 'Agent', tool_use_id: id, tool_input: { description: `look into ${id}`, subagent_type: type, prompt: 'p' } })
  send(d, 'agent-start', { agent_id: `ag-${id}`, agent_type: type })
  if (opts.background) send(d, 'post', { tool_name: 'Agent', tool_use_id: id, tool_input: {}, tool_response: { status: 'async_launched' } })
}

test('a helper agent shows as a running row with its type and task', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  launch(d, 'A1', 'Explore')
  const steps = Object.values(sess(d).steps)
  assert.strictEqual(steps.length, 1, 'the Agent call and SubagentStart are one row')
  assert.strictEqual(steps[0].label, 'Helper agent (Explore)')
  assert.strictEqual(steps[0].detail, 'look into A1')
  assert.strictEqual(steps[0].agent, 'ag-A1')
})

test("the helper's own steps are labelled with its name", () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  launch(d, 'A1', 'Explore')
  send(d, 'pre', { tool_name: 'Grep', tool_use_id: 'g1', tool_input: { pattern: 'foo' }, agent_id: 'ag-A1', agent_type: 'Explore' })
  const g = sess(d).steps.g1
  assert.strictEqual(g.label, 'Explore › Searching code')
  assert.strictEqual(g.by, 'ag-A1')
  send(d, 'post', { tool_name: 'Grep', tool_use_id: 'g1', agent_id: 'ag-A1', agent_type: 'Explore' })
  assert.ok(!sess(d).steps.g1)
})

test('a background helper stays running after its Agent call returns', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  launch(d, 'A1', 'general-purpose', { background: true })
  assert.ok(sess(d).steps.A1, 'still running after async_launched')
  send(d, 'agent-stop', { agent_id: 'ag-A1', agent_type: 'general-purpose' })
  assert.ok(!sess(d).steps.A1)
  assert.strictEqual(sess(d).log.at(-1).label, 'Helper agent (general-purpose)')
})

test('the job waits for background helpers after the reply ends, then finishes', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  launch(d, 'A1', 'Explore', { background: true })
  launch(d, 'A2', 'Plan', { background: true })
  send(d, 'stop', {})
  let s = sess(d)
  assert.ok(s.turnStartedAt, 'still active'); assert.strictEqual(s.waiting, true)
  send(d, 'agent-stop', { agent_id: 'ag-A1', agent_type: 'Explore' })
  assert.ok(sess(d).turnStartedAt, 'one helper left')
  send(d, 'agent-stop', { agent_id: 'ag-A2', agent_type: 'Plan' })
  s = sess(d)
  assert.strictEqual(s.turnStartedAt, null); assert.ok(s.finishedAt); assert.strictEqual(s.waiting, false)
})

test('parallel helpers each claim their own Agent call by type', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'pre', { tool_name: 'Agent', tool_use_id: 'X', tool_input: { description: 'x', subagent_type: 'Explore' } })
  send(d, 'pre', { tool_name: 'Agent', tool_use_id: 'Y', tool_input: { description: 'y', subagent_type: 'Plan' } })
  send(d, 'agent-start', { agent_id: 'ag-y', agent_type: 'Plan' })
  send(d, 'agent-start', { agent_id: 'ag-x', agent_type: 'Explore' })
  const s = sess(d).steps
  assert.strictEqual(s.X.agent, 'ag-x'); assert.strictEqual(s.Y.agent, 'ag-y')
})

test('a helper with no Agent call (e.g. a resumed one) gets its own row', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'agent-start', { agent_id: 'ag-r', agent_type: 'Explore' })
  const rows = Object.values(sess(d).steps)
  assert.strictEqual(rows.length, 1); assert.strictEqual(rows[0].agent, 'ag-r')
})

test("Claude's internal agents (no type) are ignored", () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  send(d, 'stop', {})
  send(d, 'agent-start', { agent_id: 'internal', agent_type: '' })
  send(d, 'agent-stop', { agent_id: 'internal', agent_type: '' })
  const s = sess(d)
  assert.strictEqual(s.turnStartedAt, null); assert.deepStrictEqual(s.steps, {})
})

test('a new prompt keeps helpers that are still working', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'one' })
  launch(d, 'A1', 'Explore', { background: true })
  send(d, 'stop', {})
  send(d, 'prompt', { prompt: 'two' })
  assert.ok(sess(d).steps.A1)
})

test('helpers silent for 2 hours are forgotten', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  launch(d, 'A1', 'Explore', { background: true })
  const f = path.join(d, 'state.json'); const st = JSON.parse(fs.readFileSync(f, 'utf8'))
  st.sessions.S.steps.A1.startedAt -= 7300000; fs.writeFileSync(f, JSON.stringify(st))
  send(d, 'pre', { tool_name: 'Read', tool_use_id: 'r', tool_input: {} })
  assert.ok(!sess(d).steps.A1)
})

test("a finished helper's late Agent result never closes another helper's row", () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  launch(d, 'A1', 'Explore')
  send(d, 'pre', { tool_name: 'Agent', tool_use_id: 'A2', tool_input: { description: 'second', subagent_type: 'Explore' } })
  send(d, 'agent-stop', { agent_id: 'ag-A1', agent_type: 'Explore' })
  send(d, 'post', { tool_name: 'Agent', tool_use_id: 'A1', tool_input: {} })
  assert.ok(sess(d).steps.A2, 'second Agent call still running')
})

test('each helper gets a role for the Team view: its type first, then its task', () => {
  const cases = [
    ['UI Designer', 'Design the hero', 'design'],
    ['UI Finish-Gate Reviewer', 'Check the hero matches the brand', 'review'],
    ['Explore', 'Find the form code', 'research'],
    ['Plan', 'Plan the refactor', 'plan'],
    ['general-purpose', 'Build the hero section in React', 'build'],
    ['general-purpose', 'Verify the design aligns with the guide', 'review'],
    ['general-purpose', 'Pen-test the installer', 'test'],
    ['general-purpose', 'Write the release notes', 'write'],
    ['general-purpose', 'Something else entirely', 'other'],
  ]
  for (const [type, task, role] of cases) {
    const d = tmp()
    send(d, 'prompt', { prompt: 'go' })
    send(d, 'pre', { tool_name: 'Agent', tool_use_id: 'A', tool_input: { description: task, subagent_type: type } })
    send(d, 'agent-start', { agent_id: 'ag', agent_type: type })
    const a = sess(d).steps.A
    assert.strictEqual(a.role, role, `${type} / ${task}`)
    assert.strictEqual(a.who, type)
  }
})

test('role and name stay on the finished helper in the log', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'go' })
  launch(d, 'A1', 'UI Designer')
  send(d, 'agent-stop', { agent_id: 'ag-A1', agent_type: 'UI Designer' })
  const done = sess(d).log.at(-1)
  assert.strictEqual(done.role, 'design'); assert.strictEqual(done.who, 'UI Designer'); assert.strictEqual(done.agent, 'ag-A1')
})

test("a helper's step count survives a new turn clearing the log", () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'one' })
  launch(d, 'A1', 'UI Designer', { background: true })
  for (const id of ['w1', 'w2']) {
    send(d, 'pre', { tool_name: 'Write', tool_use_id: id, tool_input: { file_path: 'card.html' }, agent_id: 'ag-A1', agent_type: 'UI Designer' })
    send(d, 'post', { tool_name: 'Write', tool_use_id: id, agent_id: 'ag-A1', agent_type: 'UI Designer' })
  }
  send(d, 'prompt', { prompt: 'two' })
  send(d, 'agent-stop', { agent_id: 'ag-A1', agent_type: 'UI Designer' })
  assert.strictEqual(sess(d).log.find(x => x.agent === 'ag-A1').done, 2)
})

test('finished helpers stay listed across turns while the team is still working', () => {
  const d = tmp()
  send(d, 'prompt', { prompt: 'one' })
  launch(d, 'A1', 'Explore', { background: true })
  launch(d, 'A2', 'UI Designer', { background: true })
  send(d, 'agent-stop', { agent_id: 'ag-A1', agent_type: 'Explore' })
  send(d, 'stop', {})
  send(d, 'prompt', { prompt: 'helper report' })
  assert.ok(sess(d).log.some(l => l.agent === 'ag-A1'), 'explorer still listed')
  send(d, 'agent-stop', { agent_id: 'ag-A2', agent_type: 'UI Designer' })
  send(d, 'stop', {})
  send(d, 'prompt', { prompt: 'last helper report' })
  assert.strictEqual(sess(d).log.filter(l => l.agent).length, 2, 'whole team still shown while Claude reads the last report')
  send(d, 'stop', {})
  send(d, 'prompt', { prompt: 'next job' })
  assert.deepStrictEqual(sess(d).log, [], 'the job after that starts empty')
})
