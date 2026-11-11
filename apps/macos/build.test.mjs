import test from 'node:test'
import assert from 'node:assert/strict'
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { runtimeFiles, sourceRoot } from './build.mjs'
import { defaultConfig } from './config.mjs'

const run = promisify(execFile)

test('packaged collector runs outside the checkout without providers or host packages', async () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-panel-runtime-'))
  try {
    const runtime = path.join(directory, 'runtime'), omp = path.join(directory, 'omp'), config = path.join(directory, 'config.json')
    for (const file of runtimeFiles) {
      const target = path.join(runtime, file)
      mkdirSync(path.dirname(target), { recursive: true }); copyFileSync(path.join(sourceRoot, file), target)
    }
    const payload = { reports: [{ provider: 'mistral', fetchedAt: 1, metadata: { accountName: 'Independent' }, limits: [{ id: 'monthly', label: 'Month', amount: { unit: 'percent', used: 42 } }] }] }
    writeFileSync(omp, `#!${process.execPath}\nif (JSON.stringify(process.argv.slice(2)) !== '["usage","--json"]') process.exit(9)\nprocess.stdout.write(${JSON.stringify(JSON.stringify(payload))})\n`, { mode: 0o700 })
    writeFileSync(config, JSON.stringify(defaultConfig({ nodePath: process.execPath, ompPath: omp })))
    const { stdout } = await run(process.execPath, [path.join(runtime, 'apps/macos/collect.mjs'), '--config', config], {
      cwd: directory, env: { ...process.env, HOME: directory, NODE_PATH: '' },
    })
    const result = JSON.parse(stdout)
    assert.equal(result.source, 'live'); assert.equal(result.snapshot.accounts[0].provider, 'mistral'); assert.equal(result.summaries[0].percent, 42)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})
