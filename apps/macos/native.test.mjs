import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const directory = dirname(fileURLToPath(import.meta.url))
test('native models, inline account selection and dock geometry preserve behavior', { skip: process.platform !== 'darwin' }, () => {
  const temp = mkdtempSync(join(tmpdir(), 'omp-panel-models-'))
  try {
    const executable = join(temp, 'models-tests')
    const sources = ['ExactConfigMap', 'Models', 'PanelConfigStore', 'GeneralSettingsDraft', 'CompactPreferences', 'PanelPlacement', 'UpdateModel', 'UpdatePreferences', 'DockModel', 'DashboardModel', 'ProviderDetailModel', 'DropdownModel', 'SetupModel', 'ManagedNode'].map((name) => join(directory, `native/${name}.swift`))
    const tests = ['NativeTestSupport', 'ModelsTests', 'PanelConfigStoreTests', 'GeneralSettingsDraftTests', 'CompactPreferencesTests', 'PanelPlacementTests', 'UpdateModelTests', 'UpdatePreferencesTests', 'DockModelTests', 'DashboardModelTests', 'ProviderDetailModelTests', 'DropdownModelTests', 'SetupModelTests', 'ManagedNodeTests'].map((name) => join(directory, `native-tests/${name}.swift`))
    const build = spawnSync('xcrun', ['swiftc', '-swift-version', '5', ...sources, ...tests, '-o', executable], { encoding: 'utf8' })
    assert.equal(build.status, 0, build.stderr || build.error?.message)
    const run = spawnSync(executable, [], { encoding: 'utf8' })
    assert.equal(run.status, 0, run.stderr || run.error?.message)
  } finally { rmSync(temp, { recursive: true, force: true }) }
})
test('compact wing reconciliation keeps reparented views attached in the real NSView hierarchy', { skip: process.platform !== 'darwin' }, () => {
  const temp = mkdtempSync(join(tmpdir(), 'omp-panel-hierarchy-'))
  try {
    const executable = join(temp, 'hierarchy-tests')
    const sources = [join(directory, 'native/CompactRowReconciler.swift'), join(directory, 'native-tests/CompactRowReconcilerTests.swift')]
    const build = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', ...sources, '-o', executable], { encoding: 'utf8' })
    assert.equal(build.status, 0, build.stderr || build.error?.message)
    const run = spawnSync(executable, [], { encoding: 'utf8' })
    assert.equal(run.status, 0, run.stderr || run.error?.message)
  } finally { rmSync(temp, { recursive: true, force: true }) }
})
