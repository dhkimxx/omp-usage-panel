import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm, symlink, utimes } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { mergeExternalSources } from './external-sources.mjs'
import { summarizeProviders } from '../../packages/usage-core/summary.mjs'
import { defaultConfig } from './config.mjs'
import { runtimeFiles } from './build.mjs'

/** @typedef {import('../../packages/usage-core/types.js').UsageSnapshot} UsageSnapshot */
/** @typedef {import('../../packages/usage-core/types.js').CollectionResult} CollectionResult */
const now = 2_000_000, maxAgeMs = 300_000, provider = 'google-antigravity'
const settings = defaultConfig({ nodePath: '/usr/bin/node', ompPath: '/usr/bin/omp' })
/** @param {string} owner @param {number} [time] @param {number} [fraction] @returns {UsageSnapshot} */
function snapshot(owner, time = now - 1000, fraction = 0.25) {
  return { version: 1, capturedAt: time, accounts: [{ id: `${owner}-account`, provider: owner, label: 'Quota', fetchedAt: time,
    notes: [], limits: [{ id: 'five-hour', label: '5 hours', amount: { unit: 'percent', used: fraction * 100, limit: 100, remaining: (1 - fraction) * 100 },
      usedFraction: fraction, window: { id: '5h', label: '5 hours', resetsAt: now + 60000, durationMs: 18000000 }, notes: [] }] }], unavailable: [] }
}
/** @returns {CollectionResult} */
function liveOMP() { return { source: 'live', snapshot: snapshot('mistral', now, 0.1) } }
/** @param {(file: string, merge: (raw?: unknown, omp?: CollectionResult) => Promise<CollectionResult>) => Promise<void>} body */
async function fixture(body) {
  const dir = await mkdtemp(path.join(tmpdir(), 'panel-external-')), file = path.join(dir, 'snapshot.json')
  try {
    await body(file, async (raw, omp = liveOMP()) => {
      if (raw !== undefined) await writeFile(file, typeof raw === 'string' ? raw : JSON.stringify(raw))
      return mergeExternalSources(omp, [{ providerId: provider, path: file }], { now, maxAgeMs })
    })
  } finally { await rm(dir, { recursive: true, force: true }) }
}
/** @param {unknown} data @param {string} [errorCode] */
const envelope = (data, errorCode) => ({ version: 1, providerId: provider, snapshot: data, ...(errorCode ? { errorCode } : {}) })

test('external file is merged before real summary selection; configured provider owns every OMP account/report', async () => {
  await fixture(async (_file, merge) => {
    const omp = liveOMP()
    omp.snapshot?.accounts.push(...snapshot(provider, now, 0.99).accounts, ...snapshot(provider, now, 0.88).accounts)
    omp.snapshot?.unavailable.push({ provider, label: 'OMP copy', reason: 'Old error' })
    const quota = snapshot(provider)
    quota.accounts[0].limits.push({ id: 'weekly', label: 'Week', amount: { unit: 'percent', used: 60, limit: 100, remaining: 40 }, usedFraction: 0.6, notes: [] })
    const result = await merge(envelope(quota), omp)
    const summaries = summarizeProviders(result, settings)
    assert.equal(result.source, 'live')
    assert.equal(result.error, undefined)
    assert.deepEqual(result.snapshot?.accounts.map(account => account.provider), ['mistral', provider])
    assert.deepEqual(result.snapshot?.unavailable, [])
    assert.equal(summaries.find(summary => summary.provider === provider)?.label, 'Antigravity')
    assert.equal(summaries.find(summary => summary.provider === provider)?.percent, 60)
    assert.equal(summaries.find(summary => summary.provider === provider)?.metricId, 'weekly')
    assert.equal(result.snapshot?.capturedAt, quota.capturedAt)
    assert.equal(result.snapshot?.accounts[1].fetchedAt, quota.accounts[0].fetchedAt)
    assert.equal(result.providerSources?.find(source => source.provider === 'mistral')?.capturedAt, now)
    assert.equal(result.providerSources?.find(source => source.provider === provider)?.capturedAt, quota.capturedAt)
    assert.deepEqual(result.ompSource, { source: 'live', capturedAt: now, providers: ['mistral'] })
    assert.ok(runtimeFiles.includes('apps/macos/external-sources.mjs'))
  })
})

test('disabled hook has no effect, including retaining original result identity', async () => {
  const omp = liveOMP()
  assert.equal(await mergeExternalSources(omp, [], { now, maxAgeMs }), omp)
})

test('missing/non-JSON/malformed envelopes never hide OMP data or fall back to an owned OMP provider', async () => {
  await fixture(async (file, merge) => {
    const omp = liveOMP()
    omp.snapshot?.accounts.push(...snapshot(provider).accounts)
    const invalid = [undefined, 'not JSON: private@example.test', {}, { ...envelope(snapshot(provider)), version: 2 },
      { ...envelope(snapshot(provider)), providerId: 'other' }, { ...envelope(snapshot(provider)), errorCode: 'private@example.test' },
      { ...envelope(snapshot(provider)), command: 'do not execute' }, envelope(null),
      envelope({ ...snapshot(provider), accounts: [{ ...snapshot(provider).accounts[0], notes: undefined }] }),
      envelope({ ...snapshot(provider), accounts: [{ ...snapshot(provider).accounts[0], limits: [{ id: 'bad', label: 'bad', amount: { unit: 'percent' } }] }] })]
    for (const raw of invalid) {
      const result = await merge(raw, omp)
      assert.equal(result.source, 'partial')
      assert.deepEqual(result.snapshot?.accounts.map(account => account.provider), ['mistral'])
      assert.equal(result.snapshot?.unavailable[0].provider, provider)
      const summaries = summarizeProviders(result, settings)
      assert.equal(summaries.find(summary => summary.provider === 'mistral')?.percent, 10)
      assert.equal(summaries.find(summary => summary.provider === provider)?.percent, null)
      assert.equal(result.providerSources?.find(source => source.provider === provider)?.source, 'unavailable')
      assert.ok(!JSON.stringify(result).includes('private@example.test'))
    }
    await rm(file)
    await symlink(path.join(path.dirname(file), 'absent'), file)
    assert.equal((await merge()).providerSources?.find(source => source.provider === provider)?.source, 'unavailable')
  })
})

test('snapshot ownership rejects mismatched account and unavailable provider IDs', async () => {
  await fixture(async (_file, merge) => {
    for (const data of [snapshot('other'), { ...snapshot(provider), unavailable: [{ provider: 'other', label: 'bad', reason: 'bad' }] }]) {
      const result = await merge(envelope(data))
      assert.equal(result.providerSources?.find(source => source.provider === provider)?.error, 'INVALID_OUTPUT')
      assert.ok(!result.snapshot?.accounts.some(account => account.provider === 'other'))
      assert.ok(!result.snapshot?.unavailable.some(report => report.provider === 'other'))
    }
  })
})

test('expired, future, and old fetchedAt snapshots stay stale despite new file mtimes and live OMP', async () => {
  await fixture(async (file, merge) => {
    for (const data of [snapshot(provider, now - maxAgeMs), snapshot(provider, now + 1),
      { ...snapshot(provider), accounts: [{ ...snapshot(provider).accounts[0], fetchedAt: now - maxAgeMs }] }]) {
      await writeFile(file, JSON.stringify(envelope(data)))
      await utimes(file, new Date(), new Date())
      const result = await merge()
      assert.equal(result.source, 'partial')
      assert.equal(result.snapshot?.capturedAt, Math.min(now, data.capturedAt))
      assert.equal(result.snapshot?.accounts[1].fetchedAt, data.accounts[0].fetchedAt)
      assert.equal(result.providerSources?.find(source => source.provider === provider)?.source, 'stale')
      assert.ok(summarizeProviders(result, settings).find(summary => summary.provider === provider)?.notes.some(note => note.includes('Stale data')))
      assert.deepEqual(summarizeProviders(result, settings).find(summary => summary.provider === 'mistral')?.notes, [])
    }
  })
})

test('producer error retains last good quota/timestamps and null errors remain unavailable', async () => {
  await fixture(async (_file, merge) => {
    for (const error of ['CLI_NOT_FOUND', 'AUTH_REQUIRED', 'COLLECT_FAILED', 'INVALID_OUTPUT', 'NO_QUOTA', 'UNSAFE_CONFIG']) {
      const data = snapshot(provider)
      const result = await merge(envelope(data, error))
      assert.equal(result.providerSources?.find(source => source.provider === provider)?.source, 'stale')
      assert.equal(result.providerSources?.find(source => source.provider === provider)?.error, error)
      assert.equal(result.snapshot?.accounts[1].fetchedAt, data.accounts[0].fetchedAt)
      assert.equal(summarizeProviders(result, settings).find(summary => summary.provider === provider)?.percent, 25)
      const empty = await merge(envelope(null, error))
      assert.equal(empty.providerSources?.find(source => source.provider === provider)?.source, 'unavailable')
      assert.equal(summarizeProviders(empty, settings).find(summary => summary.provider === provider)?.percent, null)
    }
  })
})

test('OMP failure does not discard a healthy external result; failures remain source-local', async () => {
  await fixture(async (_file, merge) => {
    const result = await merge(envelope(snapshot(provider)), { source: 'unavailable', snapshot: null, error: 'Usage refresh failed' })
    assert.equal(result.source, 'partial')
    assert.equal(result.providerSources?.[0].source, 'cache')
    assert.equal(summarizeProviders(result, settings)[0].percent, 25)
    assert.deepEqual(summarizeProviders(result, settings)[0].notes, [])
    const staleOMP = { snapshot: snapshot('mistral', now - maxAgeMs), source: /** @type {const} */ ('stale'), error: 'Usage refresh failed' }
    const mixed = await merge(envelope(snapshot(provider)), staleOMP)
    assert.deepEqual(mixed.providerSources?.map(source => [source.provider, source.source]), [['mistral', 'stale'], [provider, 'cache']])
    const missing = await merge(envelope(null, 'AUTH_REQUIRED'), { source: 'unavailable', snapshot: null, error: 'Usage refresh failed' })
    assert.equal(missing.source, 'unavailable')
    assert.equal(missing.snapshot, null, 'all failures must preserve the native last-good/null guard, not emit epoch zero')
    assert.deepEqual(missing.ompSource, { source: 'unavailable', capturedAt: null, providers: [], error: 'Usage refresh failed' })
  })
})

test('multiple generic external providers retain independent freshness and source ownership', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'panel-generic-'))
  try {
    const configs = [{ providerId: 'external-one', path: path.join(dir, 'one.json') }, { providerId: 'external-two', path: path.join(dir, 'two.json') }]
    for (const [index, config] of configs.entries()) await writeFile(config.path, JSON.stringify({ version: 1, providerId: config.providerId,
      snapshot: snapshot(config.providerId, index ? now - maxAgeMs : now) }))
    const result = await mergeExternalSources(liveOMP(), configs, { now, maxAgeMs })
    assert.deepEqual(result.providerSources?.map(source => [source.provider, source.source, source.capturedAt]), [
      ['mistral', 'live', now], ['external-one', 'cache', now], ['external-two', 'stale', now - maxAgeMs]])
    assert.deepEqual(summarizeProviders(result, settings).map(summary => summary.provider), ['mistral', 'external-one', 'external-two'])
  } finally { await rm(dir, { recursive: true, force: true }) }
})

test('consumer enforces the producer 1 MiB maximum before reading JSON', async () => {
  await fixture(async (_file, merge) => {
    const json = JSON.stringify(envelope(snapshot(provider)))
    const atLimit = await merge(json + ' '.repeat(1024 * 1024 - Buffer.byteLength(json)))
    assert.equal(atLimit.providerSources?.find(source => source.provider === provider)?.source, 'cache')
    const overLimit = await merge(json + ' '.repeat(1024 * 1024 + 1 - Buffer.byteLength(json)))
    assert.equal(overLimit.providerSources?.find(source => source.provider === provider)?.source, 'unavailable')
    assert.equal(overLimit.providerSources?.find(source => source.provider === provider)?.capturedAt, null)
    assert.deepEqual(overLimit.snapshot?.accounts.map(account => account.provider), ['mistral'])
  })
})

test('fresh quota with unavailable reports is explicitly degraded; no-quota accounts are never healthy', async () => {
  await fixture(async (_file, merge) => {
    const quota = snapshot(provider)
    const mixed = await merge(envelope({ ...quota, unavailable: [{ provider, label: 'Quota', reason: 'Unavailable bucket' }] }))
    assert.equal(mixed.providerSources?.find(source => source.provider === provider)?.source, 'stale')
    assert.equal(mixed.providerSources?.find(source => source.provider === provider)?.error, 'NO_QUOTA')
    assert.equal(summarizeProviders(mixed, settings).find(summary => summary.provider === provider)?.percent, 25)
    for (const limits of [[], [{ id: 'unknown', label: 'Unknown', amount: { unit: 'percent' }, notes: [] }]]) {
      const noQuota = { ...quota, accounts: [{ ...quota.accounts[0], limits }] }
      const result = await merge(envelope(noQuota))
      assert.equal(result.providerSources?.find(source => source.provider === provider)?.source, 'unavailable')
      assert.equal(result.providerSources?.find(source => source.provider === provider)?.error, 'NO_QUOTA')
      assert.equal(summarizeProviders(result, settings).find(summary => summary.provider === provider)?.percent, null)
      const alone = await merge(envelope(noQuota), { snapshot: null, source: 'unavailable', error: 'Usage refresh failed' })
      assert.equal(alone.source, 'unavailable')
      assert.equal(alone.snapshot, null)
    }
  })
})

test('all missing or unavailable-only sources return null without inventing a capture', async () => {
  await fixture(async (_file, merge) => {
    const failedOMP = { snapshot: null, source: /** @type {const} */ ('unavailable'), error: 'Usage refresh failed' }
    for (const raw of [undefined, envelope(null, 'AUTH_REQUIRED'),
      envelope({ version: 1, capturedAt: now, accounts: [], unavailable: [{ provider, label: 'Quota', reason: 'Unavailable' }] })]) {
      const result = await merge(raw, failedOMP)
      assert.equal(result.snapshot, null)
      assert.equal(result.source, 'unavailable')
    }
  })
})
