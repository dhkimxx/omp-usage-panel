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
