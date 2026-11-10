import test from 'node:test'
import assert from 'node:assert/strict'
import { defaultConfig, parseConfig, migrateSwiftbarVariables } from './config.mjs'

const base = defaultConfig({ nodePath: '/usr/local/bin/node', ompPath: '/usr/local/bin/omp' })
test('defaults and migration preserve meaningful settings', () => {
  const config = migrateSwiftbarVariables({ OMP_BIN: '/opt/bin/omp', OMP_PROFILE: 'work', OMP_USAGE_PROVIDERS: 'mistral, openai-codex,mistral', OMP_USAGE_LABELS: '{"mistral":"Team"}', OMP_USAGE_METRICS: '{"mistral":"mistral:vibe:monthly"}', OMP_USAGE_REFRESH_MINUTES: '2.5', OMP_USAGE_WARN_PERCENT: '50', OMP_USAGE_CRITICAL_PERCENT: '80', OMP_USAGE_SHOW_PACE: 'false', OMP_USAGE_DISPLAY: 'obsolete' }, base)
  assert.equal(config.ompPath, '/opt/bin/omp'); assert.equal(config.profile, 'work')
  assert.deepEqual(config.providers, ['mistral', 'openai-codex']); assert.equal(config.metrics.mistral, 'mistral:vibe:monthly')
  assert.equal(config.cacheMinutes, 2.5); assert.equal(config.refreshSeconds, 60); assert.equal(config.showPace, false)
})
test('empty legacy executable and profile values retain installed executable and use default profile', () => {
  const existing = { ...base, profile: 'work' }
  for (const value of ['', '  ']) {
    const config = migrateSwiftbarVariables({ OMP_BIN: value, OMP_PROFILE: value }, existing)
    assert.equal(config.ompPath, base.ompPath)
    assert.equal(config.profile, 'default')
  }
  assert.equal(migrateSwiftbarVariables({}, existing).profile, 'work')
})
test('invalid config and migration are rejected without exposing values', () => {
  for (const value of [{ ...base, metrics: { x: '' } }, { ...base, ompPath: 'relative' }, { ...base, criticalPercent: 10 }, { ...base, timeoutSeconds: 0 }, { ...base, providers: ['x', 'x'] }, { ...base, extra: true }]) assert.throws(() => parseConfig(value))
  for (const vars of [{ OMP_USAGE_METRICS: 'secret' }, { OMP_USAGE_PROVIDERS: 'a,,b' }, { OMP_USAGE_SHOW_PACE: 'secret' }]) {
    assert.throws(() => migrateSwiftbarVariables(vars, base), error => error instanceof Error && !error.message.includes('secret'))
  }
})
