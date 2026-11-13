import test from 'node:test'
import assert from 'node:assert/strict'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { execFile, execFileSync, spawnSync } from 'node:child_process'
import { promisify } from 'node:util'
import { runtimeFiles, sourceRoot } from './build.mjs'
import { defaultConfig } from './config.mjs'
import { ensureNodeRuntime, nodeCacheRoot, readNodePin, verifyNodeResources, writeNodeResources } from './sparkle.mjs'

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

test('packaged setup helper starts from the copied runtime alone and refuses invalid requests with a controlled error before creating anything', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-panel-setup-runtime-'))
  try {
    const runtime = path.join(directory, 'runtime'), home = path.join(directory, 'home'), helper = path.join(runtime, 'apps/macos/setup-install.mjs')
    for (const file of runtimeFiles) {
      const target = path.join(runtime, file)
      mkdirSync(path.dirname(target), { recursive: true }); copyFileSync(path.join(sourceRoot, file), target)
    }
    mkdirSync(home)
    /** @param {string} command @param {string} input @param {string} code */
    const refused = (command, input, code) => {
      const result = spawnSync(process.execPath, [helper, command], { input, encoding: 'utf8', cwd: directory, env: { ...process.env, HOME: home, NODE_PATH: '' } })
      const payload = JSON.parse(result.stdout)
      assert.equal(result.status, 1)
      assert.equal(payload.ok, false); assert.equal(payload.command, command); assert.equal(payload.error.code, code)
      // The public answer never echoes the request or the account's paths.
      assert.ok(!result.stdout.includes(directory))
    }
    const valid = { sourceAppPath: path.join(directory, 'OMP Usage.app'), hostPid: 4001 }
    // Every case fails inside the packaged modules, so a missing module of the import closure would break these at process start instead.
    refused('frobnicate', JSON.stringify(valid), 'invalid-request')
    refused('install', JSON.stringify({ ...valid, hostPid: '4001' }), 'invalid-request')
    refused('install', JSON.stringify({ ...valid, nodePath: 5 }), 'invalid-request')
    refused('launch', JSON.stringify({ ...valid, nodePath: '/bin/sh' }), 'invalid-request')
    refused('install', '[]', 'invalid-request')
    refused('install', '{ not json', 'invalid-request')
    // The request limit is 64 KiB. A request of exactly that size is read and judged on its content (the copied runtime is no app bundle, so
    // it reaches the bundle check); a single byte more is refused as oversized without being interpreted.
    const limit = 65536
    /** @param {number} bytes */
    const padded = bytes => { const body = JSON.stringify(valid); return body + ' '.repeat(bytes - Buffer.byteLength(body)) }
    refused('launch', padded(limit), 'source-mismatch')
    refused('launch', padded(limit + 1), 'invalid-request')
    // Nothing was created: no app, configuration, state or LaunchAgent under the account home.
    assert.deepEqual(readdirSync(home), [])
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

// ---------------------------------------------------------------- bundled Node runtime (fake tarballs: no network, no real Node)
/** @param {Buffer|string} data */
const sha256 = data => createHash('sha256').update(data).digest('hex')
/** Tiny stand-in for the official tarballs plus a pin describing them. @param {string} directory @param {{binarySHA256?: string}} [overrides] */
function fakeNodeDistribution(directory, { binarySHA256 } = {}) {
  const version = '9.9.9', files = new Map(), arches = /** @type {Record<string, any>} */ ({})
  for (const arch of ['arm64', 'x64']) {
    const top = `node-v${version}-darwin-${arch}`, root = path.join(directory, 'dist', arch, top), binary = Buffer.from(`fake node ${arch}\n`)
    mkdirSync(path.join(root, 'bin'), { recursive: true })
    writeFileSync(path.join(root, 'bin/node'), binary); writeFileSync(path.join(root, 'LICENSE'), 'license text\n'); writeFileSync(path.join(root, 'README.md'), 'readme\n')
    // A second LICENSE deeper in the tree must never be picked up.
    mkdirSync(path.join(root, 'lib/npm'), { recursive: true }); writeFileSync(path.join(root, 'lib/npm/LICENSE'), 'npm license\n')
    const tarball = path.join(directory, `${top}.tar.gz`)
    execFileSync('/usr/bin/tar', ['-czf', tarball, '-C', path.join(directory, 'dist', arch), top])
    const url = `https://example.invalid/dist/v${version}/${top}.tar.gz`
    files.set(url, tarball)
    arches[arch] = { url, size: statSync(tarball).size, sha256: sha256(readFileSync(tarball)), binary: { size: binary.length, sha256: binarySHA256 ?? sha256(binary) } }
  }
  const pin = { version, teamIdentifier: 'ABCDE12345', arches }
  let downloads = 0
  /** @param {string} url @param {string} destination */
  const download = (url, destination) => { downloads++; copyFileSync(/** @type {string} */ (files.get(url)), destination) }
  return { pin, download, downloads: () => downloads, signingTeam: () => 'ABCDE12345' }
}
/** @param {string} archive */
const listing = archive => execFileSync('/usr/bin/tar', ['-tf', archive], { encoding: 'utf8' }).split('\n').filter(Boolean).sort()

test('the committed Node pin parses and the cache location honours OMP_USAGE_NODE_CACHE', () => {
  const pin = readNodePin()
  assert.deepEqual(Object.keys(pin.arches).sort(), ['arm64', 'x64'])
  const previous = process.env.OMP_USAGE_NODE_CACHE
  try {
    process.env.OMP_USAGE_NODE_CACHE = '/tmp/omp-node-cache-override'
    assert.equal(nodeCacheRoot(pin), '/tmp/omp-node-cache-override')
  } finally { if (previous === undefined) delete process.env.OMP_USAGE_NODE_CACHE; else process.env.OMP_USAGE_NODE_CACHE = previous }
})

test('ensureNodeRuntime repacks only node and LICENSE, verifies them, and reuses the cached archive without downloading or recompressing', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-node-runtime-'))
  try {
    const dist = fakeNodeDistribution(directory), cache = path.join(directory, 'cache')
    assert.ok(!existsSync(cache), 'nothing is created before the runtime is requested')
    const first = ensureNodeRuntime({ arches: ['arm64', 'x64'], pin: dist.pin, cache, download: dist.download, signingTeam: dist.signingTeam })
    assert.equal(dist.downloads(), 2)
    for (const arch of ['arm64', 'x64']) {
      const entry = first.arches[arch]
      assert.deepEqual(listing(entry.file), ['LICENSE', 'node'])
      assert.equal(entry.archive, `node-${arch}.tar.xz`)
      assert.equal(entry.archiveSize, statSync(entry.file).size); assert.equal(entry.archiveSHA256, sha256(readFileSync(entry.file)))
      assert.equal(entry.binarySize, dist.pin.arches[arch].binary.size); assert.equal(entry.binarySHA256, dist.pin.arches[arch].binary.sha256)
      const mode = execFileSync('/usr/bin/tar', ['-tvf', entry.file], { encoding: 'utf8' }).split('\n').find(line => line.endsWith(' node'))
      assert.match(mode ?? '', /^-rwxr-xr-x/)
      assert.match(mode ?? '', /\sroot\s+wheel\s/, 'the archive carries a fixed owner, nothing of the builder')
    }
    const mtime = statSync(first.arches.arm64.file).mtimeMs
    const second = ensureNodeRuntime({ arches: ['arm64'], pin: dist.pin, cache, download: dist.download, signingTeam: dist.signingTeam })
    assert.equal(dist.downloads(), 2, 'the cached archive is reused')
    assert.equal(statSync(second.arches.arm64.file).mtimeMs, mtime, 'the archive was not recompressed')
    assert.deepEqual(second.arches.arm64, first.arches.arm64)
    assert.deepEqual(readdirSync(path.join(cache, 'arm64')).filter(name => name.startsWith('.') || name.endsWith('.partial')), [], 'no staging leftovers')
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

test('ensureNodeRuntime refuses a download or binary that differs from the pin and never leaves a usable archive', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-node-runtime-'))
  try {
    /** @param {string} name @param {ReturnType<typeof fakeNodeDistribution>} dist @param {Partial<Parameters<typeof ensureNodeRuntime>[0]>} options @param {RegExp} message */
    const refuse = (name, dist, options, message) => {
      const cache = path.join(directory, `cache-${name}`)
      assert.throws(() => ensureNodeRuntime({ arches: ['arm64'], pin: dist.pin, cache, download: dist.download, signingTeam: dist.signingTeam, ...options }), message, name)
      assert.ok(!existsSync(path.join(cache, 'arm64/node-arm64.tar.xz')), `${name}: no archive`)
      assert.ok(!existsSync(path.join(cache, 'arm64/node.json')), `${name}: no cache marker`)
    }
    const good = fakeNodeDistribution(path.join(directory, 'good'))
    const wrongSize = { ...good.pin, arches: { ...good.pin.arches, arm64: { ...good.pin.arches.arm64, size: good.pin.arches.arm64.size + 1 } } }
    refuse('tarball-size', good, { pin: wrongSize }, /pinned size\/SHA-256/)
    const wrongSHA = { ...good.pin, arches: { ...good.pin.arches, arm64: { ...good.pin.arches.arm64, sha256: '0'.repeat(64) } } }
    refuse('tarball-sha', good, { pin: wrongSHA }, /pinned size\/SHA-256/)
    refuse('binary-sha', fakeNodeDistribution(path.join(directory, 'bad-binary'), { binarySHA256: '1'.repeat(64) }), {}, /Extracted Node binary/)
    const wrongBinarySize = { ...good.pin, arches: { ...good.pin.arches, arm64: { ...good.pin.arches.arm64, binary: { ...good.pin.arches.arm64.binary, size: 3 } } } }
    refuse('binary-size', good, { pin: wrongBinarySize }, /Extracted Node binary/)
    refuse('signature', good, { signingTeam: () => { throw new Error('invalid signature') } }, /invalid signature/)
    refuse('team', good, { signingTeam: () => 'ZZZZZ99999' }, /signed by Team ZZZZZ99999/)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

test('a corrupted cached archive is rebuilt instead of trusted', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-node-runtime-'))
  try {
    const dist = fakeNodeDistribution(directory), cache = path.join(directory, 'cache')
    const options = { arches: ['arm64'], pin: dist.pin, cache, download: dist.download, signingTeam: dist.signingTeam }
    const first = ensureNodeRuntime(options)
    writeFileSync(first.arches.arm64.file, 'corrupt')
    const again = ensureNodeRuntime(options)
    assert.equal(sha256(readFileSync(again.arches.arm64.file)), again.arches.arm64.archiveSHA256)
    assert.deepEqual(listing(again.arches.arm64.file), ['LICENSE', 'node'])
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

test('bundled Node resources: the written layout verifies, tampering is refused, and an app without them only passes when not required', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-node-runtime-'))
  try {
    const dist = fakeNodeDistribution(directory), cache = path.join(directory, 'cache')
    const app = path.join(directory, 'OMP Usage.app'), resources = path.join(app, 'Contents/Resources/node'), pin = dist.pin
    const runtime = ensureNodeRuntime({ arches: ['arm64', 'x64'], pin, cache, download: dist.download, signingTeam: dist.signingTeam })
    writeNodeResources(resources, runtime)
    assert.deepEqual(readdirSync(resources).sort(), ['manifest.json', 'node-arm64.tar.xz', 'node-x64.tar.xz'])
    const manifest = JSON.parse(readFileSync(path.join(resources, 'manifest.json'), 'utf8'))
    assert.deepEqual(Object.keys(manifest), ['schema', 'version', 'teamIdentifier', 'arches'])
    assert.equal(manifest.schema, 1); assert.equal(manifest.version, pin.version); assert.equal(manifest.teamIdentifier, pin.teamIdentifier)
    assert.deepEqual(Object.keys(manifest.arches.arm64), ['archive', 'archiveSize', 'archiveSHA256', 'binarySize', 'binarySHA256'])
    assert.equal(verifyNodeResources(app, { required: true, pin }), true)

    // A host-only (non-universal) build lists one architecture: fine unless every architecture is required.
    const hostOnly = path.join(directory, 'host.app')
    writeNodeResources(path.join(hostOnly, 'Contents/Resources/node'), ensureNodeRuntime({ arches: ['arm64'], pin, cache, download: dist.download, signingTeam: dist.signingTeam }))
    assert.equal(verifyNodeResources(hostOnly, { pin }), true)
    assert.throws(() => verifyNodeResources(hostOnly, { required: true, pin }), /every supported architecture/)

    const none = path.join(directory, 'old.app'); mkdirSync(path.join(none, 'Contents/Resources'), { recursive: true })
    assert.equal(verifyNodeResources(none, { pin }), false)
    assert.throws(() => verifyNodeResources(none, { required: true, pin }), /no bundled Node runtime/)

    const manifestFile = path.join(resources, 'manifest.json'), archive = path.join(resources, 'node-arm64.tar.xz')
    const original = readFileSync(manifestFile, 'utf8'), archiveBytes = readFileSync(archive)
    /** @param {(manifest: any) => void} mutate */
    const rewrite = mutate => { const value = JSON.parse(original); mutate(value); writeFileSync(manifestFile, JSON.stringify(value)) }
    rewrite(value => { value.version = '9.9.8' }); assert.throws(() => verifyNodeResources(app, { required: true, pin }), /pinned/)
    assert.equal(verifyNodeResources(app, { required: true, matchPin: false }), true, 'a published release is never compared with the current pin')
    rewrite(value => { value.teamIdentifier = 'ZZZZZ99999' }); assert.throws(() => verifyNodeResources(app, { required: true, pin }), /team identifier/)
    assert.equal(verifyNodeResources(app, { required: true, matchPin: false }), true)
    rewrite(value => { value.arches.arm64.binarySHA256 = '2'.repeat(64) }); assert.throws(() => verifyNodeResources(app, { required: true, pin }), /binary differs from the pin/)
    rewrite(value => { value.arches.arm64.archiveSHA256 = '3'.repeat(64) }); assert.throws(() => verifyNodeResources(app, { required: true, pin }), /archive differs from its manifest/)
    assert.throws(() => verifyNodeResources(app, { required: true, matchPin: false }), /archive differs from its manifest/, 'self-consistency is still enforced without a pin')
    rewrite(value => { value.extra = true }); assert.throws(() => verifyNodeResources(app, { required: true, pin }), /exactly the keys/)
    writeFileSync(manifestFile, original)
    writeFileSync(archive, Buffer.concat([archiveBytes, Buffer.from('x')]))
    assert.throws(() => verifyNodeResources(app, { required: true, pin }), /archive differs from its manifest/)
    writeFileSync(archive, archiveBytes)
    writeFileSync(path.join(resources, 'stray'), 'x')
    assert.throws(() => verifyNodeResources(app, { required: true, pin }), /files the manifest does not list/)
    rmSync(path.join(resources, 'stray'))
    assert.equal(verifyNodeResources(app, { required: true, pin }), true)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})
