import test from 'node:test'
import assert from 'node:assert/strict'
import { defaultConfig, parseConfig } from './config.mjs'

const base = defaultConfig({ nodePath: '/usr/local/bin/node', ompPath: '/usr/local/bin/omp' })
test('invalid configuration is rejected', () => {
  for (const value of [{ ...base, metrics: { x: '' } }, { ...base, ompPath: 'relative' }, { ...base, criticalPercent: 10 }, { ...base, timeoutSeconds: 0 }, { ...base, providers: ['x', 'x'] }, { ...base, extra: true }]) assert.throws(() => parseConfig(value))
})
