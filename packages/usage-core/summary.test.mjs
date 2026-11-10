import test from 'node:test'
import assert from 'node:assert/strict'
import { summarizeProviders, formatPercent } from './summary.mjs'

/** @typedef {import('./types.js').UsageLimit} UsageLimit */
/** @param {string} id @param {number|undefined} usedFraction @param {string} [status] @returns {UsageLimit} */
function limit(id, usedFraction, status) { return { id, label: id, amount: { unit: 'percent' }, notes: [], ...(usedFraction === undefined ? {} : { usedFraction }), ...(status ? { status } : {}) } }
/** @param {string} id @param {string} provider @param {UsageLimit[]} limits @returns {import('./types.js').UsageAccount} */
function account(id, provider, limits) { return { id, provider, label: id, fetchedAt: 1, notes: [], limits } }
const settings = { providers: null, labels: {}, metrics: {}, warnPercent: 70, criticalPercent: 90 }
/** @param {import('./types.js').UsageAccount[]} accounts @param {import('./types.js').UsageUnavailable[]} [unavailable] @returns {import('./types.js').CollectionResult} */
function result(accounts, unavailable = []) { return { source: 'live', snapshot: { version: 1, capturedAt: 1, accounts, unavailable } } }

test('selects maximum across accounts, deterministic ties, exact metrics and overage', () => {
  const data = result([account('z', 'mistral', [limit('a', 1.2), limit('b', 0.8, 'exhausted')]), account('a', 'mistral', [limit('a', 1.2)])])
  const [s] = summarizeProviders(data, settings)
  assert.equal(s.value, '120%'); assert.equal(s.accountId, 'a'); assert.equal(s.accountCount, 2); assert.equal(s.severity, 'critical')
  const [filtered] = summarizeProviders(data, { ...settings, metrics: { mistral: 'b' } })
  assert.equal(filtered.percent, 80); assert.equal(filtered.severity, 'critical')
  const [missing] = summarizeProviders(data, { ...settings, metrics: { mistral: 'monthly' } })
  assert.equal(missing.percent, null)
})
test('unknown exhaustion, zero, provider order and unavailability remain distinct', () => {
  const data = result([account('a', 'mistral', [limit('x', undefined, 'exhausted')]), account('b', 'openai-codex', [limit('x', 0)])], [{ provider: 'other', label: 'Other', reason: 'Unavailable' }])
  const summaries = summarizeProviders(data, settings)
  assert.deepEqual(summaries.map(x => x.provider), ['openai-codex', 'mistral', 'other'])
  assert.equal(summaries[0].value, '0%'); assert.equal(summaries[1].severity, 'critical'); assert.equal(summaries[1].value, '—'); assert.equal(summaries[2].severity, 'unknown')
  assert.equal(summarizeProviders(data, { ...settings, providers: ['missing'], labels: { missing: 'Custom' } })[0].label, 'Custom')
})
test('formatting does not promote values across severity boundaries', () => {
  assert.equal(formatPercent(0.001), '<0.1%')
  assert.equal(formatPercent(69.99999999999999), '69.9%')
  assert.equal(formatPercent(89.99999999999999), '89.9%')
  assert.equal(formatPercent(99.99999999999999), '99.9%')
  assert.equal(formatPercent(49.99999999999999, { warnPercent: 50 }), '49.9%')
})
