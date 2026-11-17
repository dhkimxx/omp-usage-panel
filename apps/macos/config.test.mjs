import test from 'node:test'
import assert from 'node:assert/strict'
import { defaultConfig, parseConfig } from './config.mjs'

const base = defaultConfig({ nodePath: '/usr/local/bin/node', ompPath: '/usr/local/bin/omp' })
test('invalid configuration is rejected', () => {
  for (const value of [{ ...base, metrics: { x: '' } }, { ...base, ompPath: 'relative' }, { ...base, criticalPercent: 10 }, { ...base, timeoutSeconds: 0 }, { ...base, providers: ['x', 'x'] }, { ...base, extra: true }]) assert.throws(() => parseConfig(value))
})
test('external sources are strict opt-ins and legacy files decode to no sources', () => {
  const { externalSources, ...legacy } = base
  assert.deepEqual(externalSources, [])
  assert.deepEqual(parseConfig(legacy).externalSources, [])
  const sources = [{ providerId: 'google-antigravity', path: '/private/quota.json' }]
  assert.deepEqual(parseConfig({ ...base, externalSources: sources }).externalSources, sources)
  for (const externalSources of [null, {}, [null], [{ providerId: '', path: '/q' }], [{ providerId: 'p', path: 'relative' }],
    [{ providerId: 'p', path: '/q', command: 'not allowed' }], [{ providerId: 'p', path: '/q\0' }], [...sources, ...sources]]) {
    assert.throws(() => parseConfig({ ...base, externalSources }))
  }
})
