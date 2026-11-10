import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const directory = dirname(fileURLToPath(import.meta.url))
test('native models, dashboard selection and dock geometry preserve behavior', { skip: process.platform !== 'darwin' }, () => {
  const temp = mkdtempSync(join(tmpdir(), 'omp-panel-models-'))
  try {
    const executable = join(temp, 'models-tests')
    const build = spawnSync('xcrun', ['swiftc', '-swift-version', '5', join(directory, 'native/Models.swift'), join(directory, 'native/DockModel.swift'), join(directory, 'native/DashboardModel.swift'), join(directory, 'native-tests/ModelsTests.swift'), join(directory, 'native-tests/DockModelTests.swift'), join(directory, 'native-tests/DashboardModelTests.swift'), '-o', executable], { encoding: 'utf8' })
    assert.equal(build.status, 0, build.stderr || build.error?.message)
    const run = spawnSync(executable, [], { encoding: 'utf8' })
    assert.equal(run.status, 0, run.stderr || run.error?.message)
  } finally { rmSync(temp, { recursive: true, force: true }) }
})
