import { createHash } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
export const channelPath = path.join(sourceRoot, 'apps/macos/update-channel.json')
export const feedPath = path.join(sourceRoot, 'updates/appcast.xml')
export const sparkle = Object.freeze({
  version: '2.10.1',
  url: 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz',
  size: 16346336,
  sha256: '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27',
})
export const defaults = Object.freeze({
  repository: 'dhkimxx/omp-usage-panel',
  feedURL: 'https://raw.githubusercontent.com/dhkimxx/omp-usage-panel/main/updates/appcast.xml',
  account: 'dhkimxx.omp-usage-panel',
  namespace: 'https://github.com/dhkimxx/omp-usage-panel/updates',
  minimumSystemVersion: '13.0',
})

export function rootVersion() {
  const { version } = JSON.parse(readFileSync(path.join(sourceRoot, 'package.json'), 'utf8'))
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`Root package.json version must be MAJOR.MINOR.PATCH, got ${JSON.stringify(version)}`)
  return version
}

/** @param {string} file */
function sha256File(file) { return createHash('sha256').update(readFileSync(file)).digest('hex') }

export function sparkleCacheRoot() {
  return path.resolve(process.env.OMP_USAGE_SPARKLE_CACHE || path.join(homedir(), 'Library/Caches/omp-usage-panel/sparkle', sparkle.version))
}

/** @typedef {{root: string, framework: string, license: string, signUpdate: string, generateKeys: string}} SparkleSdk */
/**
 * Download (if needed) and verify the pinned Sparkle archive, then extract it only after the digest matches.
 * @returns {SparkleSdk}
 */
export function ensureSparkleSdk() {
  const cache = sparkleCacheRoot(), archive = path.join(cache, `Sparkle-${sparkle.version}.tar.xz`), root = path.join(cache, 'sdk'), marker = path.join(cache, 'sdk.sha256')
  mkdirSync(cache, { recursive: true })
  /** @param {string} file */
  const verified = file => existsSync(file) && statSync(file).size === sparkle.size && sha256File(file) === sparkle.sha256
  if (!verified(archive)) {
    rmSync(archive, { force: true })
    const temp = `${archive}.partial`
    rmSync(temp, { force: true })
    try {
      execFileSync('/usr/bin/curl', ['--fail', '--location', '--proto', '=https', '--silent', '--show-error', '--output', temp, sparkle.url], { stdio: 'inherit' })
      if (!verified(temp)) throw new Error('Downloaded Sparkle archive does not match the pinned size/SHA-256')
      renameSync(temp, archive)
    } finally { rmSync(temp, { force: true }) }
  }
  const sdkReady = existsSync(path.join(root, 'Sparkle.framework/Versions/B/Sparkle')) && existsSync(marker) && readFileSync(marker, 'utf8').trim() === sparkle.sha256
  if (!sdkReady) {
    const stage = mkdtempSync(path.join(cache, '.extract-'))
    try {
      execFileSync('/usr/bin/tar', ['-xJf', archive, '-C', stage], { stdio: 'inherit' })
      for (const required of ['Sparkle.framework', 'bin/sign_update', 'bin/generate_keys', 'LICENSE']) if (!existsSync(path.join(stage, required))) throw new Error(`Sparkle archive is missing ${required}`)
      rmSync(root, { recursive: true, force: true })
      renameSync(stage, root)
      writeFileSync(marker, `${sparkle.sha256}\n`)
    } finally { rmSync(stage, { recursive: true, force: true }) }
  }
  return { root, framework: path.join(root, 'Sparkle.framework'), license: path.join(root, 'LICENSE'), signUpdate: path.join(root, 'bin/sign_update'), generateKeys: path.join(root, 'bin/generate_keys') }
}

// ---------------------------------------------------------------- bundled Node runtime
// The app carries the pinned official Node as one compressed archive per architecture. The archive is built here from the official
// tarball (size + SHA-256 + Developer ID team verified) and cached, so repeated builds never download or recompress. The bundled
// archive is never executed in place: the app extracts it at runtime into its own managed location.
export const nodeRuntimePath = path.join(sourceRoot, 'apps/macos/node-runtime.json')
export const nodeArches = Object.freeze(['arm64', 'x64'])

/** @typedef {{size: number, sha256: string}} NodeBinaryPin */
/** @typedef {{url: string, size: number, sha256: string, binary: NodeBinaryPin}} NodeArchPin */
/** @typedef {{version: string, teamIdentifier: string, arches: Record<string, NodeArchPin>}} NodePin */
/** @typedef {{archive: string, archiveSize: number, archiveSHA256: string, binarySize: number, binarySHA256: string}} NodeManifestEntry */
/** @typedef {{schema: 1, version: string, teamIdentifier: string, arches: Record<string, NodeManifestEntry>}} NodeManifest */
/** @typedef {NodeManifestEntry & {file: string}} NodeArchive */
/** @typedef {{pin: NodePin, arches: Record<string, NodeArchive>}} NodeRuntime */

/** @param {unknown} value @returns {value is Record<string, unknown>} */
function isRecord(value) { return typeof value === 'object' && value !== null && !Array.isArray(value) }
/** @param {unknown} value @returns {value is number} */
function isSize(value) { return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 }
/** @param {unknown} value @returns {value is string} */
function isDigest(value) { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value) }
/** @param {Record<string, unknown>} value @param {string[]} keys @param {string} label */
function requireKeys(value, keys, label) {
  if (Object.keys(value).sort().join() !== [...keys].sort().join()) throw new Error(`${label} must have exactly the keys ${keys.join(', ')}`)
}

/** Validates the bytes of node-runtime.json. Pure. @param {string|Uint8Array} data @returns {NodePin} */
export function parseNodePin(data) {
  const value = JSON.parse(typeof data === 'string' ? data : Buffer.from(data).toString('utf8'))
  if (!isRecord(value)) throw new Error('node-runtime.json must be an object')
  requireKeys(value, ['version', 'teamIdentifier', 'arches'], 'node-runtime.json')
  if (typeof value.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(value.version)) throw new Error('node-runtime.json version must be MAJOR.MINOR.PATCH')
  if (typeof value.teamIdentifier !== 'string' || !/^[A-Z0-9]{10}$/.test(value.teamIdentifier)) throw new Error('node-runtime.json teamIdentifier is not a Team ID')
  if (!isRecord(value.arches)) throw new Error('node-runtime.json arches must be an object')
  requireKeys(value.arches, [...nodeArches], 'node-runtime.json arches')
  /** @type {Record<string, NodeArchPin>} */
  const arches = {}
  for (const arch of nodeArches) {
    const entry = value.arches[arch]
    if (!isRecord(entry)) throw new Error(`node-runtime.json ${arch} must be an object`)
    requireKeys(entry, ['url', 'size', 'sha256', 'binary'], `node-runtime.json ${arch}`)
    const { url, size, sha256, binary } = entry
    if (typeof url !== 'string' || !url.startsWith('https://') || !/\.tar\.gz$/.test(url)) throw new Error(`node-runtime.json ${arch} url must be an https .tar.gz URL`)
    if (!isSize(size) || !isDigest(sha256)) throw new Error(`node-runtime.json ${arch} size/sha256 are invalid`)
    if (!isRecord(binary)) throw new Error(`node-runtime.json ${arch} binary must be an object`)
    requireKeys(binary, ['size', 'sha256'], `node-runtime.json ${arch} binary`)
    if (!isSize(binary.size) || !isDigest(binary.sha256)) throw new Error(`node-runtime.json ${arch} binary size/sha256 are invalid`)
    arches[arch] = { url, size, sha256, binary: { size: binary.size, sha256: binary.sha256 } }
  }
  return { version: value.version, teamIdentifier: value.teamIdentifier, arches }
}

/** @param {string} [file] @returns {NodePin} */
export function readNodePin(file = nodeRuntimePath) { return parseNodePin(readFileSync(file, 'utf8')) }

/**
 * Architecture key (`arm64` | `x64`) of the Mac, matching how the app picks its managed Node: arm64 whenever the hardware is arm64-capable,
 * even when this process is an x64 Node running under Rosetta.
 */
export function hostNodeArch() {
  try { if (execFileSync('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() === '1') return 'arm64' } catch { /* key absent on Intel Macs */ }
  return 'x64'
}

/** @param {NodePin} pin */
export function nodeCacheRoot(pin) {
  return path.resolve(process.env.OMP_USAGE_NODE_CACHE || path.join(homedir(), 'Library/Caches/omp-usage-panel/node', pin.version))
}

/** @param {string} url @param {string} destination */
function curlDownload(url, destination) {
  execFileSync('/usr/bin/curl', ['--fail', '--location', '--proto', '=https', '--silent', '--show-error', '--output', destination, url], { stdio: 'inherit' })
}

/** Verifies the code signature strictly and returns the signing Team ID. @param {string} file @returns {string} */
function codesignTeam(file) {
  execFileSync('/usr/bin/codesign', ['--verify', '--strict', file], { stdio: 'pipe' })
  const shown = spawnSync('/usr/bin/codesign', ['-dv', '--verbose=2', file], { encoding: 'utf8' })
  const team = /^TeamIdentifier=(.+)$/m.exec(shown.stderr ?? '')?.[1]
  if (shown.status !== 0 || !team) throw new Error(`Cannot read the code signature of ${file}`)
  return team
}

/** @param {string} file @param {number} size @param {string} sha256 */
const matches = (file, size, sha256) => existsSync(file) && statSync(file).size === size && sha256File(file) === sha256

/**
 * Builds (or reuses from the cache) the verified `node-<arch>.tar.xz` of one architecture.
 * @param {string} arch @param {{pin: NodePin, cache: string, download: (url: string, destination: string) => void, signingTeam: (file: string) => string}} options
 * @returns {NodeArchive}
 */
function ensureNodeArchive(arch, { pin, cache, download, signingTeam }) {
  const entry = pin.arches[arch]
  if (!entry) throw new Error(`No pinned Node runtime for ${arch}`)
  const dir = path.join(cache, arch), tarball = path.join(dir, path.basename(new URL(entry.url).pathname)), name = `node-${arch}.tar.xz`, packed = path.join(dir, name), marker = path.join(dir, 'node.json')
  const top = path.basename(tarball, '.tar.gz')
  mkdirSync(dir, { recursive: true })
  const identity = { schema: 1, version: pin.version, teamIdentifier: pin.teamIdentifier, tarballSHA256: entry.sha256, binarySize: entry.binary.size, binarySHA256: entry.binary.sha256 }
  /** @param {string} archiveSHA256 @param {number} archiveSize @returns {NodeArchive} */
  const result = (archiveSHA256, archiveSize) => ({ file: packed, archive: name, archiveSize, archiveSHA256, binarySize: entry.binary.size, binarySHA256: entry.binary.sha256 })
  if (existsSync(marker)) {
    try {
      const cached = JSON.parse(readFileSync(marker, 'utf8'))
      if (isRecord(cached) && Object.entries(identity).every(([key, value]) => cached[key] === value) && isSize(cached.archiveSize) && isDigest(cached.archiveSHA256) && matches(packed, cached.archiveSize, cached.archiveSHA256)) return result(cached.archiveSHA256, cached.archiveSize)
    } catch { /* unreadable marker: rebuild */ }
  }
  rmSync(marker, { force: true })
  if (!matches(tarball, entry.size, entry.sha256)) {
    rmSync(tarball, { force: true })
    const temp = `${tarball}.partial`
    rmSync(temp, { force: true })
    try {
      download(entry.url, temp)
      if (!matches(temp, entry.size, entry.sha256)) throw new Error(`Downloaded Node archive for ${arch} does not match the pinned size/SHA-256`)
      renameSync(temp, tarball)
    } finally { rmSync(temp, { force: true }) }
  }
  const stage = mkdtempSync(path.join(dir, '.extract-')), pack = mkdtempSync(path.join(dir, '.pack-'))
  try {
    execFileSync('/usr/bin/tar', ['-xzf', tarball, '-C', stage, `${top}/bin/node`, `${top}/LICENSE`], { stdio: 'inherit' })
    const node = path.join(stage, top, 'bin/node'), license = path.join(stage, top, 'LICENSE')
    if (!existsSync(license)) throw new Error(`Node archive for ${arch} is missing LICENSE`)
    if (!matches(node, entry.binary.size, entry.binary.sha256)) throw new Error(`Extracted Node binary for ${arch} does not match the pinned size/SHA-256`)
    const team = signingTeam(node)
    if (team !== pin.teamIdentifier) throw new Error(`Node binary for ${arch} is signed by Team ${team}, expected ${pin.teamIdentifier}`)
    // Only `node` and `LICENSE`, fixed timestamps and owner, no AppleDouble entries: the archive carries nothing but the verified bytes and nothing of the builder.
    copyFileSync(node, path.join(pack, 'node')); chmodSync(path.join(pack, 'node'), 0o755)
    copyFileSync(license, path.join(pack, 'LICENSE')); chmodSync(path.join(pack, 'LICENSE'), 0o644)
    for (const file of ['node', 'LICENSE']) utimesSync(path.join(pack, file), 0, 0)
    const partial = `${packed}.partial`
    rmSync(partial, { force: true })
    try {
      execFileSync('/usr/bin/tar', ['--format', 'ustar', '--uid', '0', '--gid', '0', '--uname', 'root', '--gname', 'wheel', '-cJf', partial, '-C', pack, 'node', 'LICENSE'], { stdio: 'inherit', env: { ...process.env, COPYFILE_DISABLE: '1' } })
      renameSync(partial, packed)
    } finally { rmSync(partial, { force: true }) }
  } finally {
    rmSync(stage, { recursive: true, force: true })
    rmSync(pack, { recursive: true, force: true })
  }
  const archiveSize = statSync(packed).size, archiveSHA256 = sha256File(packed)
  writeFileSync(marker, `${JSON.stringify({ ...identity, archiveSize, archiveSHA256 })}\n`)
  return result(archiveSHA256, archiveSize)
}

/**
 * Lazily prepares the verified Node archives for `arches` (default: the host architecture). Nothing is created or downloaded until called.
 * `pin`, `cache`, `download` and `signingTeam` are seams for tests; the defaults are the committed pin, the cache directory, curl and codesign.
 * @param {{arches?: string[], pin?: NodePin, cache?: string, download?: (url: string, destination: string) => void, signingTeam?: (file: string) => string}} [options]
 * @returns {NodeRuntime}
 */
export function ensureNodeRuntime({ arches = [hostNodeArch()], pin = readNodePin(), cache = nodeCacheRoot(pin), download = curlDownload, signingTeam = codesignTeam } = {}) {
  /** @type {Record<string, NodeArchive>} */
  const built = {}
  for (const arch of arches) built[arch] = ensureNodeArchive(arch, { pin, cache, download, signingTeam })
  return { pin, arches: built }
}

/** @param {NodeRuntime} runtime @returns {NodeManifest} */
export function nodeManifest({ pin, arches }) {
  return {
    schema: 1, version: pin.version, teamIdentifier: pin.teamIdentifier,
    arches: Object.fromEntries(Object.entries(arches).map(([arch, { archive, archiveSize, archiveSHA256, binarySize, binarySHA256 }]) => [arch, { archive, archiveSize, archiveSHA256, binarySize, binarySHA256 }])),
  }
}

/** Writes `manifest.json` and the archives into the (absent or empty) `directory`. @param {string} directory @param {NodeRuntime} runtime */
export function writeNodeResources(directory, runtime) {
  mkdirSync(directory, { recursive: true })
  for (const { file, archive } of Object.values(runtime.arches)) copyFileSync(file, path.join(directory, archive))
  writeFileSync(path.join(directory, 'manifest.json'), `${JSON.stringify(nodeManifest(runtime), null, 2)}\n`)
}

/** First app version that bundles the Node runtime; releases before it have no `Contents/Resources/node`. */
export const firstBundledNodeVersion = '1.1.0'
/** @param {string} version MAJOR.MINOR.PATCH @returns {boolean} whether an app of this version must carry the bundled Node resources */
export function hasBundledNode(version) {
  const a = version.split('.').map(Number), b = firstBundledNodeVersion.split('.').map(Number)
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i]
  return true
}

/**
 * Checks the bundled Node resources of one app.
 * Always (structural, self-consistency only): strict manifest keys/types, every listed archive present with matching size and SHA-256,
 * archive entries exactly `node` (0755) and `LICENSE`, and no stray files. A release is never compared with the current pin here,
 * so published releases keep verifying after the pin moves.
 * `required`: the app must carry the resources (and every supported architecture). Apps built before the runtime was bundled
 * have none and pass otherwise.
 * `matchPin` (default: `required`; for newly built apps and CI candidates): also compares version, team and binary identity with the
 * pin and hashes the `node` bytes inside each archive against pin.binary.
 * @param {string} app @param {{required?: boolean, matchPin?: boolean, pin?: NodePin|undefined}} [options]
 * @returns {boolean} whether the app carries a bundled runtime
 */
export function verifyNodeResources(app, { required = false, matchPin = required, pin } = {}) {
  const directory = path.join(app, 'Contents/Resources/node')
  if (!existsSync(directory)) {
    if (required) throw new Error('App has no bundled Node runtime (Contents/Resources/node)')
    return false
  }
  const expected = matchPin ? (pin ?? readNodePin()) : undefined
  let manifest
  try { manifest = JSON.parse(readFileSync(path.join(directory, 'manifest.json'), 'utf8')) } catch { throw new Error('Bundled Node manifest.json is missing or is not valid JSON') }
  if (!isRecord(manifest)) throw new Error('Bundled Node manifest must be an object')
  requireKeys(manifest, ['schema', 'version', 'teamIdentifier', 'arches'], 'Bundled Node manifest')
  if (manifest.schema !== 1) throw new Error('Bundled Node manifest schema is not 1')
  if (typeof manifest.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(manifest.version)) throw new Error('Bundled Node manifest version must be MAJOR.MINOR.PATCH')
  if (typeof manifest.teamIdentifier !== 'string' || !/^[A-Z0-9]{10}$/.test(manifest.teamIdentifier)) throw new Error('Bundled Node manifest teamIdentifier is not a Team ID')
  if (expected && manifest.version !== expected.version) throw new Error(`Bundled Node ${manifest.version} differs from the pinned ${expected.version}`)
  if (expected && manifest.teamIdentifier !== expected.teamIdentifier) throw new Error('Bundled Node team identifier differs from the pin')
  if (!isRecord(manifest.arches)) throw new Error('Bundled Node manifest arches must be an object')
  const present = Object.keys(manifest.arches).sort()
  if (!present.length || present.some(arch => !nodeArches.includes(arch))) throw new Error('Bundled Node manifest lists an unknown or no architecture')
  if (required && present.join() !== [...nodeArches].sort().join()) throw new Error('Bundled Node manifest must list every supported architecture')
  const expectedFiles = ['manifest.json']
  for (const arch of present) {
    const entry = manifest.arches[arch]
    if (!isRecord(entry)) throw new Error(`Bundled Node ${arch} entry must be an object`)
    requireKeys(entry, ['archive', 'archiveSize', 'archiveSHA256', 'binarySize', 'binarySHA256'], `Bundled Node ${arch} entry`)
    if (entry.archive !== `node-${arch}.tar.xz`) throw new Error(`Bundled Node ${arch} archive name is not node-${arch}.tar.xz`)
    if (!isSize(entry.binarySize) || !isDigest(entry.binarySHA256)) throw new Error(`Bundled Node ${arch} binary size/SHA-256 are invalid`)
    const pinned = expected?.arches[arch]
    if (expected && (!pinned || entry.binarySize !== pinned.binary.size || entry.binarySHA256 !== pinned.binary.sha256)) throw new Error(`Bundled Node ${arch} binary differs from the pin`)
    const file = path.join(directory, entry.archive)
    if (!isSize(entry.archiveSize) || !isDigest(entry.archiveSHA256) || !matches(file, entry.archiveSize, entry.archiveSHA256)) throw new Error(`Bundled Node ${arch} archive differs from its manifest`)
    const listing = execFileSync('/usr/bin/tar', ['-tvf', file], { encoding: 'utf8' }).split('\n').filter(Boolean).map(line => ({ mode: line.split(/\s+/)[0], name: line.split(/\s+/).at(-1) }))
    const node = listing.find(item => item.name === 'node'), license = listing.find(item => item.name === 'LICENSE')
    if (listing.length !== 2 || !node || !license || node.mode !== '-rwxr-xr-x' || !license.mode?.startsWith('-')) throw new Error(`Bundled Node ${arch} archive must hold exactly an executable node and LICENSE`)
    if (pinned) {
      // The bytes users will run: a stale or poisoned cache must never yield a release whose binary fails the app's own check.
      const bytes = execFileSync('/usr/bin/tar', ['-xOf', file, 'node'], { maxBuffer: pinned.binary.size + 1024 * 1024 })
      if (bytes.length !== pinned.binary.size || createHash('sha256').update(bytes).digest('hex') !== pinned.binary.sha256) throw new Error(`Bundled Node ${arch} archive holds a node binary that differs from the pin`)
    }
    expectedFiles.push(entry.archive)
  }
  if (readdirSync(directory).sort().join() !== expectedFiles.sort().join()) throw new Error('Bundled Node directory holds files the manifest does not list')
  return true
}

/**
 * Validates the bytes of update-channel.json against the project update channel. Pure: callers decide where the bytes come from.
 * @param {string|Uint8Array} data @returns {{feedURL:string, publicEDKey:string, account:string, namespace:string}}
 */
export function parseChannel(data) {
  const value = JSON.parse(typeof data === 'string' ? data : Buffer.from(data).toString('utf8'))
  if (value.feedURL !== defaults.feedURL || value.account !== defaults.account || value.namespace !== defaults.namespace) throw new Error('update-channel.json does not match the project update channel')
  if (typeof value.publicEDKey !== 'string' || Buffer.from(value.publicEDKey, 'base64').length !== 32 || Buffer.from(value.publicEDKey, 'base64').toString('base64') !== value.publicEDKey) throw new Error('update-channel.json publicEDKey is not a valid Ed25519 public key')
  return { feedURL: value.feedURL, publicEDKey: value.publicEDKey, account: value.account, namespace: value.namespace }
}

/** @returns {{feedURL:string, publicEDKey:string, account:string, namespace:string}} */
export function readChannel() {
  if (!existsSync(channelPath)) throw new Error('apps/macos/update-channel.json is missing; run `npm run release:setup` first')
  return parseChannel(readFileSync(channelPath, 'utf8'))
}
