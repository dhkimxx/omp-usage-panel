import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { defaultConfig } from './config.mjs'

const run = promisify(execFile)
const bridge = fileURLToPath(new URL('./collect.mjs', import.meta.url))

test('live data survives a forced refresh failure and no-data failure remains unavailable', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'panel-collect-'))
  try {
    const bin = path.join(dir, 'omp'), configPath = path.join(dir, 'config.json')
    const config = defaultConfig({ nodePath: process.execPath, ompPath: bin })
    await writeFile(configPath, JSON.stringify(config))
    const payload = { reports: [{ provider: 'mistral', fetchedAt: 1, metadata: { accountName: 'Test' }, limits: [{ id: 'monthly', label: 'Month', amount: { unit: 'percent', used: 123 } }] }] }
    await writeFile(bin, `#!${process.execPath}\nprocess.stdout.write(${JSON.stringify(JSON.stringify(payload))})\n`, { mode: 0o700 })
    const env = { ...process.env, HOME: dir }
    const invoke = async (/** @type {string[]} */ args, /** @type {NodeJS.ProcessEnv} */ environment = env) => JSON.parse((await run(process.execPath, [bridge, '--config', configPath, ...args], { env: environment })).stdout)
    const live = await invoke([])
    assert.equal(live.source, 'live'); assert.equal(live.summaries[0].percent, 123); assert.equal(live.summaries[0].severity, 'critical')
    await writeFile(bin, `#!${process.execPath}\nprocess.stderr.write('private error'); process.exit(1)\n`, { mode: 0o700 })
    const stale = await invoke(['--refresh'])
    assert.equal(stale.source, 'stale'); assert.equal(stale.summaries[0].value, '123%')
    const empty = await invoke(['--refresh'], { ...env, HOME: path.join(dir, 'other-home') })
    assert.equal(empty.source, 'unavailable'); assert.equal(empty.snapshot, null); assert.deepEqual(empty.summaries, [])
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('a removed provider leaves the next successful snapshot and is never resurrected by a later failure', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'panel-removal-'))
  try {
    const bin = path.join(dir, 'omp'), configPath = path.join(dir, 'config.json')
    await writeFile(configPath, JSON.stringify(defaultConfig({ nodePath: process.execPath, ompPath: bin })))
    /** @param {string} provider @param {string} name */
    const report = (provider, name) => ({ provider, fetchedAt: 1, metadata: { accountName: name }, limits: [{ id: 'monthly', label: 'Month', amount: { unit: 'percent', used: 10 } }] })
    /** @param {unknown} payload */
    const succeedWith = payload => writeFile(bin, `#!${process.execPath}\nprocess.stdout.write(${JSON.stringify(JSON.stringify(payload))})\n`, { mode: 0o700 })
    const fail = () => writeFile(bin, `#!${process.execPath}\nprocess.stderr.write('private error'); process.exit(1)\n`, { mode: 0o700 })
    const env = { ...process.env, HOME: dir }
    const invoke = async (/** @type {string[]} */ args) => JSON.parse((await run(process.execPath, [bridge, '--config', configPath, ...args], { env })).stdout)
    /** @param {{summaries: {provider: string, accountCount: number}[]}} result */
    const counts = result => Object.fromEntries(result.summaries.map(summary => [summary.provider, summary.accountCount]))

    await succeedWith({ reports: [report('openai-codex', 'codex'), report('opencode-go', 'go'), report('mistral', 'one'), report('mistral', 'two')] })
    assert.deepEqual(counts(await invoke([])), { 'openai-codex': 1, 'opencode-go': 1, mistral: 2 })

    // opencode-go is removed, one mistral account is removed, and minimax's usage fetch fails (an unavailable
    // report, not an absence). Inside the cache window the earlier snapshot is still served; removal becomes
    // visible on the next refresh past it (or an explicit forced refresh).
    await succeedWith({ reports: [report('openai-codex', 'codex'), report('mistral', 'one')], accountsWithoutUsage: [{ provider: 'minimax-code-cn', email: 'failed@example.test' }] })
    const cached = await invoke([])
    assert.equal(cached.source, 'cache'); assert.equal(counts(cached)['opencode-go'], 1)
    const removed = await invoke(['--refresh'])
    assert.equal(removed.source, 'live')
    assert.deepEqual(counts(removed), { 'openai-codex': 1, 'minimax-code-cn': 0, mistral: 1 })
    assert.ok(!removed.snapshot.accounts.some((/** @type {{provider: string}} */ account) => account.provider === 'opencode-go'))
    assert.deepEqual(removed.snapshot.unavailable.map((/** @type {{provider: string}} */ item) => item.provider), ['minimax-code-cn'])

    // A failed refresh serves the LAST successful snapshot (which no longer contains the removed provider).
    await fail()
    const stale = await invoke(['--refresh'])
    assert.equal(stale.source, 'stale'); assert.deepEqual(counts(stale), counts(removed))

    // Every provider removed: an empty successful snapshot is a real result, not an unavailable one.
    await succeedWith({ reports: [] })
    const empty = await invoke(['--refresh'])
    assert.equal(empty.source, 'live'); assert.deepEqual(empty.snapshot.accounts, []); assert.deepEqual(empty.summaries, [])
    await fail()
    const emptyStale = await invoke(['--refresh'])
    assert.equal(emptyStale.source, 'stale'); assert.deepEqual(emptyStale.summaries, [])
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('invalid config and command arguments fail without leaking their contents', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'panel-invalid-'))
  try {
    const configPath = path.join(dir, 'config.json')
    await writeFile(configPath, '{"private":"secret"}')
    await assert.rejects(run(process.execPath, [bridge, '--config', configPath]), /** @param {unknown} error */ error => {
      if (!(error instanceof Error) || !('stderr' in error) || typeof error.stderr !== 'string') return false
      return !error.stderr.includes('secret')
    })
    await assert.rejects(run(process.execPath, [bridge, '--config', 'relative']))
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('symlinked runtime entry rejects invalid CLI arguments', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'panel-symlink-'))
  try {
    const runtime = path.join(dir, 'runtime')
    await symlink(path.dirname(bridge), runtime, 'dir')
    await assert.rejects(run(process.execPath, [path.join(runtime, 'collect.mjs'), '--config', 'relative']), /** @param {unknown} error */ error => {
      if (!(error instanceof Error) || !('code' in error) || !('stdout' in error)) return false
      return error.code === 1 && error.stdout === ''
    })
  } finally { await rm(dir, { recursive: true, force: true }) }
})
