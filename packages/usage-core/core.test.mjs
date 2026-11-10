import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { collectUsage, normalizeUsage, collectorOptionsFromEnv } from './index.mjs';

const report = { provider: 'commandcode', fetchedAt: 123, metadata: { accountId: 'one', email: 'one@example.test', planType: 'pro', monthly: { used: 15, limit: 10, remaining: -5, usedFraction: 1.5 } }, limits: [
  { id: 'commandcode:monthly', label: 'Monthly', scope: { sharedGroup: 'monthly' }, amount: { unit: 'credits', remaining: -5 } },
  { id: 'commandcode:balance', label: 'Balance', scope: { sharedGroup: 'monthly' }, amount: { unit: 'credits', remaining: -5 } },
  { id: 'pool-a', label: 'Pool A', amount: { unit: 'percent', used: 80, limit: 200, usedFraction: 1.2 } },
  { id: 'pool-b', label: 'Pool B', amount: { unit: 'percent', used: 25 } },
  { id: 'pool-c', label: 'Pool C', amount: { unit: 'tokens', remainingFraction: 0.3 } },
  { id: 'unknown', label: 'Unknown', amount: { unit: 'tokens', used: -1, limit: 0 } },
] };

test('normalization preserves accounts, arbitrary pools, explicit overage and unknown values', () => {
  const snapshot = normalizeUsage({ reports: [report, { ...report, metadata: { accountId: 'two' } }], accountsWithoutUsage: [{ provider: 'mistral', email: 'missing@example.test' }], disabledCredentials: [{ provider: 'other' }] }, 456);
  assert.equal(snapshot.capturedAt, 456);
  assert.equal(snapshot.accounts.length, 2);
  assert.notEqual(snapshot.accounts[0]?.id, snapshot.accounts[1]?.id);
  const limits = snapshot.accounts[0]?.limits ?? [];
  assert.deepEqual(limits.map(l => l.id), ['commandcode:monthly', 'pool-a', 'pool-b', 'pool-c', 'unknown']);
  assert.deepEqual(limits[0]?.amount, { unit: 'credits', used: 15, limit: 10, remaining: -5 });
  assert.deepEqual(limits.map(l => l.usedFraction), [1.5, 1.2, 0.25, 0.7, undefined]);
  assert.equal(limits[4]?.amount.used, -1);
  assert.equal(snapshot.accounts[0]?.fetchedAt, 123);
  assert.equal(snapshot.unavailable.length, 2);
  assert.equal(snapshot.accounts[1]?.limits[0]?.usedFraction, undefined);
  assert.throws(() => normalizeUsage({ reports: 'bad' }));
  assert.throws(() => normalizeUsage({ reports: [{ provider: 'x', fetchedAt: 1, limits: [null] }] }));
});

test('unavailable models survive without limits and ratios follow numeric precedence', () => {
  const snapshot = normalizeUsage({ reports: [{ provider: 'minimax', fetchedAt: 1, metadata: { unavailableModels: ['model-x'] }, limits: [
    { id: 'a', label: 'A', amount: { unit: 'percent', used: 40, limit: 50, remainingFraction: 0.8 } },
    { id: 'b', label: 'B', amount: { unit: 'tokens', usedFraction: -1, remainingFraction: 2 } },
  ] }] }, 2);
  assert.equal(snapshot.accounts[0]?.limits[0]?.usedFraction, 0.8);
  assert.equal(snapshot.accounts[0]?.limits[1]?.usedFraction, undefined);
  assert.match(snapshot.unavailable[0]?.label ?? '', /model-x/);
});

test('Mistral monthly periods estimate the preceding UTC calendar month only when needed', () => {
  /** @param {Record<string, unknown>} window */
  const normalized = (window, provider = 'mistral') => normalizeUsage({ reports: [{
    provider, fetchedAt: 1, limits: [{ id: 'budget', label: 'Budget', amount: { unit: 'EUR' }, window, notes: ['Original note'] }],
  }] }).accounts[0].limits[0];
  for (const [end, start] of [
    ['2026-12-01T00:00:00.000Z', '2026-11-01T00:00:00.000Z'],
    ['2026-01-01T12:34:56.789Z', '2025-12-01T12:34:56.789Z'],
    ['2024-03-31T12:34:56.789Z', '2024-02-29T12:34:56.789Z'],
    ['2025-03-31T12:34:56.789Z', '2025-02-28T12:34:56.789Z'],
    ['2026-05-31T00:00:00.000Z', '2026-04-30T00:00:00.000Z'],
  ]) {
    const resetsAt = Date.parse(end);
    const limit = normalized({ id: 'monthly', resetsAt });
    assert.equal(limit.window?.durationMs, resetsAt - Date.parse(start));
    assert.equal(limit.window?.estimated, true);
  }
  const actual = normalized({ id: 'monthly', resetsAt: Date.parse('2026-12-01T00:00:00Z'), durationMs: 12345 });
  assert.equal(actual.window?.durationMs, 12345);
  assert.equal(actual.window?.estimated, undefined);
  for (const resetsAt of [undefined, NaN, 8.64e15 + 1]) {
    const unknown = normalized({ id: 'monthly', resetsAt });
    assert.equal(unknown.window?.durationMs, undefined);
    assert.equal(unknown.window?.estimated, undefined);
  }
  assert.equal(normalized({ id: 'monthly', resetsAt: Date.parse('2026-12-01T00:00:00Z') }, 'other').window?.durationMs, undefined);
  assert.equal(normalized({ id: 'daily', resetsAt: Date.parse('2026-12-01T00:00:00Z') }).window?.durationMs, undefined);
  assert.equal(normalized({ id: 'monthly', resetsAt: Date.parse('2026-12-01T00:00:00Z'), durationMs: 0 }).window?.estimated, true);
});

test('cache TTL, invalidation, stale and cold failures, recovery, and profile isolation', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'omp-usage-test-'));
  t.after(async () => { await rm(dir, { recursive: true, force: true }); });
  const bin = path.join(dir, 'omp-fixture'), cacheDir = path.join(dir, 'cache');
  const control = path.join(dir, 'control'), log = path.join(dir, 'log');
  const script = `#!${process.execPath}\nconst fs = require('node:fs');\nconst args = process.argv.slice(2);\nfs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({args, profile:process.env.OMP_PROFILE || 'default'})+'\\n');\nconst mode = fs.readFileSync(${JSON.stringify(control)},'utf8');\nif(mode === 'hang') { process.on('SIGTERM', () => {}); setInterval(() => {}, 1000); return; }\nif(mode === 'fail') { console.error('secret stderr'); process.exit(1); }\nif(args[1] === 'invalidate') process.exit(0);\nif(mode === 'bad') { console.log('not json secret'); process.exit(0); }\nconsole.log(JSON.stringify({reports:[${JSON.stringify(report)}]}));\n`;
  await writeFile(bin, script, { mode: 0o700 });
  await writeFile(control, 'ok');
  const options = { ompBin: bin, cacheDir, profile: '', now: 1000 };
  const live = await collectUsage(options);
  assert.equal(live.source, 'live');
  assert.equal((await collectUsage({ ...options, now: 2000 })).source, 'cache');
  assert.equal((await collectUsage({ ...options, profile: 'default', now: 2000 })).source, 'cache');
  assert.equal((await collectUsage({ ...options, now: 3000, force: true })).source, 'live');
  let calls = (await readFile(log, 'utf8')).trim().split('\n').map(line => /** @type {{args: string[], profile: string}} */ (JSON.parse(line)));
  assert.deepEqual(calls.map(c => c.args), [['usage', '--json'], ['usage', 'invalidate'], ['usage', '--json']]);
  await writeFile(control, 'bad');
  const stale = await collectUsage({ ...options, now: 400000 });
  assert.equal(stale.source, 'stale');
  assert.equal(stale.snapshot?.capturedAt, 3000);
  assert.doesNotMatch(stale.error ?? '', /secret/);
  const cold = await collectUsage({ ...options, profile: 'other', now: 400000 });
  assert.equal(cold.source, 'unavailable');
  assert.equal(cold.snapshot, null);
  await writeFile(control, 'ok');
  assert.equal((await collectUsage({ ...options, profile: 'other', now: 400001 })).source, 'live');
  assert.equal((await collectUsage({ ...options, now: 400001 })).source, 'live');
  calls = (await readFile(log, 'utf8')).trim().split('\n').map(line => /** @type {{args: string[], profile: string}} */ (JSON.parse(line)));
  assert.equal(calls.filter(c => c.profile === 'other').length, 2);
  const files = await readdir(cacheDir);
  assert.equal(files.length, 2);
  assert.equal((await stat(cacheDir)).mode & 0o777, 0o700);
  for (const name of files) assert.equal((await stat(path.join(cacheDir, name))).mode & 0o777, 0o600);
  await writeFile(control, 'fail');
  assert.equal((await collectUsage({ ...options, now: 800000, force: true })).source, 'stale');
  await writeFile(control, 'hang');
  assert.equal((await collectUsage({ ...options, now: 800001, timeoutMs: 300 })).source, 'stale');
  await writeFile(control, 'fail');
  for (const name of files) await writeFile(path.join(cacheDir, name), '{broken');
  assert.equal((await collectUsage({ ...options, now: 800001 })).source, 'unavailable');
});

test('environment profile precedence preserves explicit empty default', () => {
  assert.deepEqual(collectorOptionsFromEnv({ OMP_BIN: '/tmp/omp', OMP_PROFILE: 'work', OMP_USAGE_CACHE_DIR: '/tmp/cache' }), { ompBin: '/tmp/omp', profile: 'work', cacheDir: '/tmp/cache' });
  assert.deepEqual(collectorOptionsFromEnv({ OMP_PROFILE: '', PI_PROFILE: 'legacy' }), { profile: '' });
  assert.deepEqual(collectorOptionsFromEnv({ PI_PROFILE: 'legacy' }), { profile: 'legacy' });
});
