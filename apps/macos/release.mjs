import { createHash, createPublicKey, verify as cryptoVerify } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { constants, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, rmdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { buildApp as buildWorkingApp } from './build.mjs'
import { DmgCleanupError, createDmg, withDmgApp } from './dmg.mjs'
import { channelPath, defaults, ensureSparkleSdk, feedPath, readChannel, rootVersion, sourceRoot } from './sparkle.mjs'

const usage = `Usage:
  node apps/macos/release.mjs setup [--public-key base64]
  node apps/macos/release.mjs package [--output directory] [--notes-file file] [--ci-run id]
  node apps/macos/release.mjs publish --notes-file file [--dry-run]
  node apps/macos/release.mjs prune --keep-version MAJOR.MINOR.PATCH [--dry-run]`

/**
 * @param {string} command @param {string[]} args @param {{cwd?: string, stdio?: import('node:child_process').StdioOptions}} [options]
 * @returns {string}
 */
function run(command, args, options = {}) { return execFileSync(command, args, { ...options, encoding: 'utf8' }) }
/** @typedef {import('./sparkle.mjs').SparkleSdk} SparkleSdk */
/** @typedef {(app: string) => string} TreeHash */
/** @typedef {import('./dmg.mjs').Hdiutil} Hdiutil */
/** @param {string[]} args */
function git(...args) { return run('/usr/bin/git', args, { cwd: sourceRoot }).trim() }
/** @param {string[]} args */
function gh(...args) { return run('gh', args, { cwd: sourceRoot }).trim() }
/** @param {string} file */
function sha256File(file) { return createHash('sha256').update(readFileSync(file)).digest('hex') }
/** @param {string} value */
const escapeXml = value => value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
/** @param {string} a @param {string} b */
function compareVersions(a, b) {
  const x = a.split('.').map(Number), y = b.split('.').map(Number)
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i]
  return 0
}

// ---------------------------------------------------------------- signing
// The private key stays in the dedicated Keychain account and is only used by Sparkle's sign_update.
// Every signature is then verified independently in Node against the committed public key, so no Keychain read is needed to verify.
const ed25519SpkiPrefix = Buffer.from('302a300506032b6570032100', 'hex')
/** @param {string} publicEDKey */
function publicKeyObject(publicEDKey) { return createPublicKey({ key: Buffer.concat([ed25519SpkiPrefix, Buffer.from(publicEDKey, 'base64')]), format: 'der', type: 'spki' }) }
/** @param {Buffer} data @param {string} signature @param {string} publicEDKey */
function verifySignature(data, signature, publicEDKey) { return cryptoVerify(null, data, publicKeyObject(publicEDKey), Buffer.from(signature, 'base64')) }
/**
 * @param {SparkleSdk} sdk @param {string} file @param {string} publicEDKey
 * @returns {{signature:string, length:number}}
 */
function signArchive(sdk, file, publicEDKey) {
  const out = run(sdk.signUpdate, ['--account', defaults.account, file])
  const match = /sparkle:edSignature="([^"]+)" length="(\d+)"/.exec(out)
  if (!match) throw new Error('sign_update returned an unexpected result')
  const length = Number(match[2])
  if (length !== statSync(file).size) throw new Error('Signed archive length does not match the file size')
  if (!verifySignature(readFileSync(file), match[1], publicEDKey)) throw new Error('Archive signature does not verify against the pinned public key')
  return { signature: match[1], length }
}
/** @param {SparkleSdk} sdk @param {string} file @param {string} publicEDKey */
function signFeed(sdk, file, publicEDKey) {
  run(sdk.signUpdate, ['--account', defaults.account, '--disable-signing-warning', file])
  verifyFeed(file, publicEDKey)
}
/** Feed signature covers every byte before the trailing sparkle-signatures comment. */
/** @param {string} text @param {string} publicEDKey @param {string} label @returns {string} */
export function verifyFeedText(text, publicEDKey, label) {
  const marker = text.lastIndexOf('<!-- sparkle-signatures:')
  const match = marker < 0 ? null : /^<!-- sparkle-signatures:\s*edSignature: (\S+)\s*length: (\d+)\s*-->\s*$/.exec(text.slice(marker))
  if (!match) throw new Error(`Feed is not signed: ${label}`)
  const signed = Buffer.from(text.slice(0, marker))
  if (signed.length !== Number(match[2]) || !verifySignature(signed, match[1], publicEDKey)) throw new Error(`Feed signature does not verify against the pinned public key: ${label}`)
  return text
}
/** @param {string} file @param {string} publicEDKey @returns {string} */
export function verifyFeed(file, publicEDKey) { return verifyFeedText(readFileSync(file, 'utf8'), publicEDKey, file) }

// ---------------------------------------------------------------- appcast
/** @param {string} text */
export function feedItems(text) { return [...text.matchAll(/<item>[\s\S]*?<\/item>/g)].map(m => m[0]) }
/** @param {string} item */
function itemVersion(item) {
  const match = /<sparkle:version>([^<]+)<\/sparkle:version>/.exec(item)
  if (!match) throw new Error('Feed item without sparkle:version')
  return match[1]
}
/** @param {string[]} items */
function renderFeed(items) {
  const body = items.map(item => `    ${item.trim()}\n`).join('')
  return `<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:omp="${defaults.namespace}">\n  <channel>\n    <title>OMP Usage</title>\n    <link>https://github.com/${defaults.repository}</link>\n    <description>Signed OMP Usage application updates</description>\n    <language>en</language>\n${body}  </channel>\n</rss>\n`
}
/** @param {{version:string, url:string, length:number, signature:string, appTreeSHA256:string, sourceCommit?: string|undefined, notes:string, pubDate:string}} release */
function renderItem(release) {
  if (release.notes.includes(']]>')) throw new Error('Release notes must not contain "]]>"')
  return `<item>
      <title>OMP Usage ${escapeXml(release.version)}</title>
      <pubDate>${release.pubDate}</pubDate>
      <sparkle:version>${release.version}</sparkle:version>
      <sparkle:shortVersionString>${release.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${defaults.minimumSystemVersion}</sparkle:minimumSystemVersion>
      <omp:appTreeSHA256>${release.appTreeSHA256}</omp:appTreeSHA256>
${release.sourceCommit ? `      <omp:sourceCommit>${release.sourceCommit}</omp:sourceCommit>\n` : ''}      <description sparkle:descriptionFormat="plain-text"><![CDATA[${release.notes}]]></description>
      <enclosure url="${escapeXml(release.url)}" length="${release.length}" type="application/octet-stream" sparkle:edSignature="${release.signature}" />
    </item>`
}
/** @param {string} feedText @param {Parameters<typeof renderItem>[0]} release */
function appendRelease(feedText, release) {
  const items = feedItems(feedText)
  for (const item of items) if (compareVersions(release.version, itemVersion(item)) <= 0) throw new Error(`Version ${release.version} is not newer than feed version ${itemVersion(item)}`)
  return renderFeed([...items, renderItem(release)])
}
export function emptyFeed() { return renderFeed([]) }
/** Public release asset: a read-only compressed DMG holding the app and an install note. @param {string} version */
export const archiveName = version => `OMP-Usage-${version}.dmg`
/** @param {string} version */
const releaseTag = version => `v${version}`
/** @param {string} version */
export const downloadURL = version => `https://github.com/${defaults.repository}/releases/download/${releaseTag(version)}/${archiveName(version)}`
/** @param {Date} date */
const rfc822 = date => date.toUTCString().replace('GMT', '+0000')

// ---------------------------------------------------------------- commands
/** @param {{publicKey?: string|undefined}} options  `publicKey` resumes an interrupted setup for a key that already exists in the Keychain. */
function setup({ publicKey } = {}) {
  const sdk = ensureSparkleSdk()
  let publicEDKey = publicKey
  if (!publicEDKey) {
    // Creates the key in the dedicated Keychain account if absent, otherwise reuses it. Never exports it.
    run(sdk.generateKeys, ['--account', defaults.account], { stdio: ['inherit', 'inherit', 'inherit'] })
    publicEDKey = run(sdk.generateKeys, ['--account', defaults.account, '-p']).trim()
  }
  if (Buffer.from(publicEDKey, 'base64').length !== 32 || Buffer.from(publicEDKey, 'base64').toString('base64') !== publicEDKey) throw new Error('Invalid Sparkle public key')
  if (existsSync(channelPath)) {
    if (readChannel().publicEDKey !== publicEDKey) throw new Error('update-channel.json already pins a different public key; refusing to change the update trust root')
  } else {
    writeFileSync(channelPath, `${JSON.stringify({ feedURL: defaults.feedURL, publicEDKey, account: defaults.account, namespace: defaults.namespace }, null, 2)}\n`)
  }
  mkdirSync(path.dirname(feedPath), { recursive: true })
  // Signing uses the Keychain key; verification is independent, so a key that differs from the pinned one is rejected here.
  if (!existsSync(feedPath)) {
    writeFileSync(feedPath, emptyFeed())
    try { signFeed(sdk, feedPath, publicEDKey) } catch (error) { rmSync(feedPath, { force: true }); throw error }
  } else if (readFileSync(feedPath, 'utf8') === emptyFeed()) {
    // Resume an interrupted setup: only the exact canonical unsigned empty feed may be signed in place.
    signFeed(sdk, feedPath, publicEDKey)
  } else verifyFeed(feedPath, publicEDKey)
  console.log(JSON.stringify({ channel: path.relative(sourceRoot, channelPath), feed: path.relative(sourceRoot, feedPath), publicEDKey }, null, 2))
}

/** @typedef {{signArchive: (file: string) => {signature: string, length: number}, signFeed: (file: string) => void}} Signer */
/**
 * Signer backed by the Keychain account through Sparkle's sign_update; every signature is verified in Node against the pinned key.
 * @param {SparkleSdk} sdk @param {string} publicEDKey @returns {Signer}
 */
function keychainSigner(sdk, publicEDKey) { return { signArchive: file => signArchive(sdk, file, publicEDKey), signFeed: file => signFeed(sdk, file, publicEDKey) } }

/**
 * Builds the universal app and hands it to `body`. With a clean tree the app is built from a private `git archive` snapshot of the
 * pinned commit, so the compiled bytes are exactly the committed bytes; only then is `sourceCommit` set (and later signed into the feed item).
 * A dirty tree builds the working source and carries no claim, so publish rejects it; `requireClean` refuses that case up front.
 * @template T
 * @param {{outputDirectory: string, requireClean?: boolean}} options
 * @param {(built: {app: string, appTreeHash: TreeHash, sourceCommit: string|undefined}) => T | Promise<T>} body
 * @returns {Promise<Awaited<T>>}
 */
export async function withReleaseApp({ outputDirectory, requireClean = false }, body) {
  const startCommit = git('rev-parse', 'HEAD'), startClean = git('status', '--porcelain') === ''
  if (requireClean && !startClean) throw new Error('The working tree must be clean: only committed source is built into a release')
  const snapshot = startClean ? mkdtempSync(path.join(tmpdir(), 'omp-release-source-')) : undefined
  try {
    /** @type {{buildApp: typeof buildWorkingApp}} */
    let builder = { buildApp: buildWorkingApp }
    /** @type {{appTreeHash: TreeHash}} */
    let ownership = await import('./ownership.mjs')
    if (snapshot) {
      const tarball = path.join(snapshot, 'source.tar'), root = path.join(snapshot, 'source')
      mkdirSync(root)
      git('archive', '--format=tar', '--output', tarball, startCommit)
      run('/usr/bin/tar', ['-xf', tarball, '-C', root])
      rmSync(tarball)
      // The snapshot's own modules define sourceRoot, so build.mjs reads only committed runtime files, sources, channel and version.
      builder = await import(pathToFileURL(path.join(root, 'apps/macos/build.mjs')).href)
      ownership = await import(pathToFileURL(path.join(root, 'apps/macos/ownership.mjs')).href)
    }
    const { appTreeHash } = ownership
    const app = builder.buildApp({ outputDirectory, universal: true })
    const sourceCommit = snapshot && git('rev-parse', 'HEAD') === startCommit ? startCommit : undefined
    return await body({ app, appTreeHash, sourceCommit })
  } finally {
    if (snapshot) rmSync(snapshot, { recursive: true, force: true })
  }
}

/**
 * Signs one DMG whose bytes are already final and writes the candidate feed and release.json beside it. Every release producer (the local build
 * and the authenticated CI candidate) goes through here, so signing is always preceded by a read-only mount inspection (`inspect` returns the
 * app tree hash) and the archive is provably never rewritten: its SHA-256 is identical before the inspection and after signing, and equals
 * `expectedSHA256` when the caller pins the bytes it authenticated.
 * @param {{archive: string, version: string, notes: string, sourceCommit: string|undefined, currentFeed: string, inspect: (archive: string) => string, signer: Signer, pubDate?: string|undefined, expectedSHA256?: string|undefined, ci?: Record<string, string|number>|undefined}} options
 * @returns {{archive: string, sha256: string, appTreeSHA256: string}}
 */
export function prepareArchive({ archive, version, notes, sourceCommit, currentFeed, inspect, signer, pubDate = rfc822(new Date()), expectedSHA256, ci }) {
  if (path.basename(archive) !== archiveName(version)) throw new Error(`Release archive must be named ${archiveName(version)}`)
  const stage = path.dirname(archive), sha256 = sha256File(archive)
  if (expectedSHA256 !== undefined && sha256 !== expectedSHA256) throw new Error('Archive bytes differ from the authenticated CI candidate')
  const appTreeSHA256 = inspect(archive)
  if (sha256File(archive) !== sha256) throw new Error('Archive changed while it was inspected')
  const { signature, length } = signer.signArchive(archive)
  if (sha256File(archive) !== sha256 || length !== statSync(archive).size) throw new Error('Archive changed while it was signed')
  const release = { version, url: downloadURL(version), length, signature, appTreeSHA256, sourceCommit, notes, pubDate }
  const feed = path.join(stage, 'appcast.xml')
  writeFileSync(feed, appendRelease(currentFeed, release))
  signer.signFeed(feed)
  writeFileSync(path.join(stage, 'release.json'), `${JSON.stringify({ ...release, archive: archiveName(version), archiveSHA256: sha256, sourceCommit: sourceCommit ?? null, ...(ci ? { ci } : {}) }, null, 2)}\n`)
  return { archive, sha256, appTreeSHA256 }
}

/**
 * Builds the DMG from the built app, verifies it through a read-only mount, signs it and writes the candidate feed and release.json into `stage`.
 * @param {{app: string, stage: string, version: string, notes: string, sourceCommit: string|undefined, currentFeed: string, appTreeHash: TreeHash, signer: Signer, pubDate?: string}} options
 */
export function createPreparedPackage({ app, stage, version, notes, sourceCommit, currentFeed, appTreeHash, signer, pubDate = rfc822(new Date()) }) {
  verifyUniversal(app)
  const archive = path.join(stage, archiveName(version))
  createDmg({ app, output: archive })
  prepareArchive({ archive, version, notes, sourceCommit, currentFeed, inspect: file => verifyArchive(file, app, appTreeHash), signer, pubDate })
}

/**
 * One authenticated CI candidate: `archivePath` is the DMG file GitHub built and attested (a path to the downloaded file, not the bare file name
 * recorded in candidate.json), `sha256` its digest at authentication time and `manifest` the identity it was authenticated against
 * (`ci-release.mjs` produces it; this module relies on nothing else in it).
 * @typedef {{archivePath: string, sha256: string, manifest: {sourceCommit: string, appTreeSHA256: string}, provenance: Record<string, string|number>}} CiCandidate
 */

/**
 * Prepares a release package from the exact DMG bytes of an authenticated CI candidate: the bytes are copied unchanged into `stage`, inspected
 * through a read-only mount against the candidate's tree hash and signed in place. The image is never rebuilt, repacked or modified.
 * @param {{candidate: CiCandidate, stage: string, version: string, notes: string, currentFeed: string, appTreeHash: TreeHash, signer: Signer, pubDate?: string|undefined}} options
 */
export function prepareFromCandidate({ candidate, stage, version, notes, currentFeed, appTreeHash, signer, pubDate }) {
  const archive = path.join(stage, archiveName(version))
  copyFileSync(candidate.archivePath, archive, constants.COPYFILE_EXCL)
  return prepareArchive({
    archive, version, notes, sourceCommit: candidate.manifest.sourceCommit, currentFeed, signer, pubDate,
    expectedSHA256: candidate.sha256, ci: candidate.provenance,
    inspect: file => inspectArchive({ file, version, appTreeHash, expectedAppTreeSHA256: candidate.manifest.appTreeSHA256, expectedFrom: 'the CI candidate manifest' }),
  })
}

/** @param {{outputDirectory?: string|undefined, notes?: string|undefined, ciRun?: string|undefined}} options */
async function packageRelease({ outputDirectory, notes, ciRun } = {}) {
  const version = rootVersion(), channel = readChannel()
  const publicEDKey = channel.publicEDKey
  const output = path.resolve(outputDirectory || path.join(sourceRoot, 'build/release', version))
  if (existsSync(output)) throw new Error(`Release output already exists: ${output}`)
  if (ciRun !== undefined) return packageCiRelease({ runId: ciRun, output, notes, version, publicEDKey })
  const sdk = ensureSparkleSdk()
  const parent = path.dirname(output); mkdirSync(parent, { recursive: true })
  const stage = mkdtempSync(path.join(parent, '.omp-release-'))
  try {
    await withReleaseApp({ outputDirectory: path.join(stage, 'build') }, ({ app, appTreeHash, sourceCommit }) => {
      createPreparedPackage({ app, stage, version, notes: notes ?? `OMP Usage ${version}`, sourceCommit, currentFeed: existsSync(feedPath) ? readFileSync(feedPath, 'utf8') : emptyFeed(), appTreeHash, signer: keychainSigner(sdk, publicEDKey) })
    })
    rmSync(path.join(stage, 'build'), { recursive: true, force: true })
    renameSync(stage, output)
  } finally {
    rmSync(stage, { recursive: true, force: true })
  }
  return output
}

/**
 * Promotes an authenticated CI candidate: the exact DMG bytes GitHub built and attested are signed with the local Keychain key.
 * Every check that can refuse (local checkout, version and release state, run, artifact, provenance) runs before the Sparkle SDK or the Keychain is touched.
 * @param {{runId: string, output: string, notes: string|undefined, version: string, publicEDKey: string}} options
 * @returns {Promise<string>}
 */
async function packageCiRelease({ runId, output, notes, version, publicEDKey }) {
  const { appTreeHash } = await import('./ownership.mjs')
  const { withVerifiedCandidate } = await import('./ci-release.mjs')
  const head = requireCleanMain({ dryRun: false, dirty: 'Working tree must be clean before packaging a CI candidate', branch: 'Package a CI candidate from the main branch' })
  gh('auth', 'status')
  const currentFeed = verifyFeed(feedPath, publicEDKey)
  assertNewerThanFeed(currentFeed, version)
  assertNotReleased(version, head)
  const parent = path.dirname(output); mkdirSync(parent, { recursive: true })
  withTemporaryDirectory(parent, '.omp-release-', stage => withVerifiedCandidate({ runId, version, head }, candidate => {
    prepareFromCandidate({ candidate, stage, version, notes: notes ?? `OMP Usage ${version}`, currentFeed, appTreeHash, signer: keychainSigner(ensureSparkleSdk(), publicEDKey) })
    renameSync(stage, output)
  }))
  return output
}

/** @param {string} app */
function verifyUniversal(app) {
  const executables = [path.join(app, 'Contents/MacOS/OMPUsagePanel')]
  for (const file of executables) {
    const archs = run('/usr/bin/lipo', ['-archs', file]).trim().split(/\s+/).sort().join(' ')
    if (archs !== 'arm64 x86_64') throw new Error(`${file} is not universal (${archs})`)
  }
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app])
}

/**
 * Round-trips the image through a read-only mount (exact layout, universal deep-signed app) and returns the tree hash of the
 * mounted app; it must equal the built app's.
 * @param {string} archive @param {string} builtApp @param {TreeHash} appTreeHash
 */
function verifyArchive(archive, builtApp, appTreeHash) {
  return withDmgApp(archive, mounted => {
    verifyUniversal(mounted)
    const hash = appTreeHash(mounted)
    if (hash !== appTreeHash(builtApp)) throw new Error('DMG mount changed the app tree')
    return hash
  })
}

/**
 * Read-only mount check of one DMG that never executes the app: the exact payload layout, a universal deep-signed app, and an Info.plist
 * version equal to `version`. Returns the app tree hash, which must equal `expectedAppTreeSHA256` when one is given
 * (`expectedFrom` names where that value came from, for the refusal message).
 * `hdiutil` replaces the system tool used to attach the image (the default is `/usr/bin/hdiutil`).
 * @param {{file: string, version: string, appTreeHash: TreeHash, expectedAppTreeSHA256?: string|undefined, expectedFrom?: string, hdiutil?: Hdiutil | undefined}} options
 * @returns {string}
 */
export function inspectArchive({ file, version, appTreeHash, expectedAppTreeSHA256, expectedFrom = 'the signed feed', hdiutil }) {
  return withDmgApp(file, extracted => {
    verifyUniversal(extracted)
    const info = run('/usr/bin/plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', path.join(extracted, 'Contents/Info.plist')]).trim()
    if (info !== version) throw new Error(`Archive app version ${info} differs from ${version}`)
    const hash = appTreeHash(extracted)
    if (expectedAppTreeSHA256 !== undefined && hash !== expectedAppTreeSHA256) throw new Error(`Archive app tree hash differs from ${expectedFrom}`)
    return hash
  }, hdiutil ? { hdiutil } : undefined)
}

/** @param {string} item */
function sourceCommitOf(item) { return /<omp:sourceCommit>([a-f0-9]{40})<\/omp:sourceCommit>/.exec(item)?.[1] }

/**
 * Fields of one feed item; throws when the enclosure, tree hash or notes are missing or malformed.
 * @param {string} item
 */
export function parseItem(item) {
  const enclosure = /<enclosure url="([^"]+)" length="(\d+)" type="application\/octet-stream" sparkle:edSignature="([^"]+)" \/>/.exec(item)
  const hash = /<omp:appTreeSHA256>([a-f0-9]{64})<\/omp:appTreeSHA256>/.exec(item)
  const description = /<description sparkle:descriptionFormat="plain-text"><!\[CDATA\[([\s\S]*)\]\]><\/description>/.exec(item)
  if (!enclosure || !hash || !description) throw new Error('Candidate feed item is malformed')
  return { url: enclosure[1], length: Number(enclosure[2]), signature: enclosure[3], appTreeSHA256: hash[1], notes: description[1], sourceCommit: sourceCommitOf(item) }
}

/**
 * True only when the signed candidate feed of a prepared package attests a clean build of `head`.
 * @param {string} output @param {string} publicEDKey @param {string} head
 */
function hasCleanProvenance(output, publicEDKey, head) {
  try { return sourceCommitOf(feedItems(verifyFeed(path.join(output, 'appcast.xml'), publicEDKey)).at(-1) ?? '') === head } catch { return false }
}

/**
 * Authenticates a prepared package against its signed candidate feed before any network mutation.
 * @param {{output: string, version: string, notes: string, publicEDKey: string, currentFeed: string, appTreeHash: TreeHash, head: string}} options
 */
export function verifyPrepared({ output, version, notes, publicEDKey, currentFeed, appTreeHash, head }) {
  const feedText = verifyFeed(path.join(output, 'appcast.xml'), publicEDKey)
  const items = feedItems(feedText), item = items.at(-1)
  if (!item || itemVersion(item) !== version) throw new Error('Candidate feed does not end with the version being published')
  const previous = feedItems(currentFeed)
  if (items.length !== previous.length + 1 || previous.some((old, index) => old.trim() !== items[index].trim())) throw new Error('Candidate feed does not extend the current signed feed')
  const parsed = parseItem(item)
  if (parsed.sourceCommit !== head) throw new Error('Package was not built from the clean pinned HEAD commit; remove it to rebuild')
  if (parsed.url !== downloadURL(version)) throw new Error('Candidate feed enclosure URL is not the release asset URL')
  if (parsed.notes !== notes) throw new Error('Candidate feed notes differ from the supplied notes')
  const archive = path.join(output, archiveName(version))
  return { archive, url: parsed.url, sha256: verifyReleaseAsset({ file: archive, item: parsed, version, publicEDKey, appTreeHash }) }
}

/**
 * Authenticates one release asset against its signed feed item: length, Ed25519 signature over the exact bytes (checked before the
 * image is ever mounted), then a read-only mount that must hold exactly the app and install note, a universal deep-signed app of
 * the expected version, and the signed trusted tree hash. Returns the asset SHA-256.
 * `hdiutil` replaces the system tool used to attach the image (the default is `/usr/bin/hdiutil`).
 * @param {{file: string, item: ReturnType<typeof parseItem>, version: string, publicEDKey: string, appTreeHash: TreeHash, hdiutil?: Hdiutil | undefined}} options
 */
export function verifyReleaseAsset({ file, item, version, publicEDKey, appTreeHash, hdiutil }) {
  const data = readFileSync(file)
  if (data.length !== item.length) throw new Error('Archive length differs from the signed feed')
  if (!verifySignature(data, item.signature, publicEDKey)) throw new Error('Archive signature does not verify against the pinned public key')
  inspectArchive({ file, version, appTreeHash, expectedAppTreeSHA256: item.appTreeSHA256, hdiutil })
  return createHash('sha256').update(data).digest('hex')
}

/** Existing remote tag must point at HEAD; returns whether the tag exists. @param {string} tag @param {string} head */
function remoteTagMatches(tag, head) {
  const lines = git('ls-remote', '--tags', 'origin', `refs/tags/${tag}`, `refs/tags/${tag}^{}`).split('\n').filter(Boolean)
  if (!lines.length) return false
  const peeled = lines.find(line => line.endsWith('^{}')) ?? lines[0]
  if (peeled.split(/\s+/)[0] !== head) throw new Error(`Tag ${tag} already exists on a different commit; refusing to reuse it`)
  return true
}

/** Throws unless the signed feed holds only versions older than `version`. @param {string} feedText @param {string} version */
function assertNewerThanFeed(feedText, version) {
  if (feedItems(feedText).some(item => itemVersion(item) === version)) throw new Error(`Version ${version} is already in the signed feed`)
  for (const item of feedItems(feedText)) if (compareVersions(version, itemVersion(item)) <= 0) throw new Error(`Version ${version} is not newer than feed version ${itemVersion(item)}`)
}

/**
 * A published version is never repackaged: an existing remote tag must already point at `head` and no GitHub release may exist for it.
 * Only an explicit "release not found" answer counts as absent; any other failure (network, auth) refuses.
 * @param {string} version @param {string} head
 */
function assertNotReleased(version, head) {
  const tag = releaseTag(version)
  remoteTagMatches(tag, head)
  try { gh('release', 'view', tag, '--repo', defaults.repository) } catch (error) {
    const detail = `${/** @type {{stderr?: unknown}} */ (error).stderr ?? ''}${error instanceof Error ? error.message : String(error)}`
    if (/release not found/i.test(detail)) return
    throw new Error(`Could not determine whether release ${tag} exists: ${detail.trim()}`)
  }
  throw new Error(`Release ${tag} already exists; a published version is never repackaged`)
}

/**
 * Returns HEAD after requiring a clean tree on `main` that equals origin/main. Dry runs stay read-only: they compare with the remote
 * branch tip via ls-remote instead of updating tracking refs.
 * @param {{dryRun: boolean, dirty: string, branch: string}} options  `dirty` and `branch` are the refusal messages for a dirty tree and a branch other than main
 */
function requireCleanMain({ dryRun, dirty, branch }) {
  if (git('status', '--porcelain')) throw new Error(dirty)
  if (git('branch', '--show-current') !== 'main') throw new Error(branch)
  if (!dryRun) git('fetch', 'origin', 'main')
  const head = git('rev-parse', 'HEAD')
  if (head !== (dryRun ? git('ls-remote', 'origin', 'refs/heads/main').split(/\s+/)[0] : git('rev-parse', 'origin/main'))) throw new Error('HEAD must equal origin/main (push or pull first)')
  return head
}

/**
 * Removes a temporary tree without ever descending into another filesystem: a volume mounted inside it is not ours to delete, so it stops
 * the removal with an error instead of being traversed. Symbolic links are removed, never followed. A missing directory is already clean.
 * @param {string} directory
 */
export function removeTemporaryTree(directory) {
  /** @type {import('node:fs').Stats} */
  let root
  try { root = lstatSync(directory) } catch (error) { if (/** @type {NodeJS.ErrnoException} */ (error).code === 'ENOENT') return; throw error }
  if (!root.isDirectory()) { unlinkSync(directory); return }
  const rootDevice = root.dev
  /** @param {string} current */
  const clear = current => {
    for (const entry of readdirSync(current)) {
      const target = path.join(current, entry), stat = lstatSync(target)
      if (stat.dev !== rootDevice) throw new Error(`Refusing to delete ${target}: it is on a different filesystem (a mounted volume?)`)
      if (stat.isDirectory()) { clear(target); rmdirSync(target) } else unlinkSync(target)
    }
  }
  clear(directory)
  rmdirSync(directory)
}

/**
 * Runs `body` in a fresh private directory under `parent` and removes it afterwards with `removeTemporaryTree`. The directory is left in place
 * when `body` failed with an uncertain DMG detach (its image may still be attached) and a failed removal never hides the original error.
 * The body must be synchronous; it may move the directory away (the removal then finds nothing).
 * @template T
 * @param {string} parent @param {string} prefix @param {(directory: string) => T} body
 * @returns {T}
 */
export function withTemporaryDirectory(parent, prefix, body) {
  const directory = mkdtempSync(path.join(parent, prefix))
  /** @type {{error: unknown} | undefined} */
  let failure
  /** @type {{value: T} | undefined} */
  let result
  try { result = { value: body(directory) } } catch (error) { failure = { error } }
  if (!(failure?.error instanceof DmgCleanupError)) {
    try { removeTemporaryTree(directory) } catch (error) { failure ??= { error } }
  }
  if (failure) throw failure.error
  return /** @type {{value: T}} */ (result).value
}

/** @param {{notesFile:string, dryRun:boolean}} options */
async function publish({ notesFile, dryRun }) {
  const { appTreeHash } = await import('./ownership.mjs')
  const version = rootVersion(), channel = readChannel(), publicEDKey = channel.publicEDKey
  const notes = readFileSync(path.resolve(notesFile), 'utf8').trim()
  if (!notes) throw new Error('Release notes file is empty')
  const head = requireCleanMain({ dryRun, dirty: 'Working tree must be clean before publishing', branch: 'Publish from the main branch' })
  gh('auth', 'status')
  const feedText = verifyFeed(feedPath, publicEDKey)
  assertNewerThanFeed(feedText, version)
  const tag = releaseTag(version), tagExists = remoteTagMatches(tag, head)
  let releaseExists = true
  try { gh('release', 'view', tag, '--repo', defaults.repository) } catch { releaseExists = false }
  if (releaseExists && !tagExists) throw new Error(`Release ${tag} exists without a matching tag; refusing to reuse it`)
  const releaseDirectory = path.join(sourceRoot, 'build/release', version)
  if (releaseExists && !existsSync(releaseDirectory)) throw new Error(`Release ${tag} already exists and no prepared package is available to verify against it`)
  const present = existsSync(releaseDirectory), clean = present && hasCleanProvenance(releaseDirectory, publicEDKey, head)
  if (dryRun) {
    // Nonmutating preview: no package deletion/build, signing, git or network writes.
    let outcome = 'would build a fresh package from the clean HEAD'
    if (present && clean) { verifyPrepared({ output: releaseDirectory, version, notes, publicEDKey, currentFeed: feedText, appTreeHash, head }); outcome = 'would reuse the verified prepared package' }
    else if (present && releaseExists) throw new Error('Release is public but the prepared package lacks clean HEAD provenance; publish would fail')
    else if (present) outcome = 'would delete the prepared package (no clean HEAD provenance) and rebuild it'
    console.log(JSON.stringify({ dryRun: true, version, tag, package: releaseDirectory, outcome, note: 'No package, signature, release, tag, upload, or commit was made' }, null, 2))
    return
  }
  // An existing package is reused only when its signed feed attests the current HEAD; otherwise it is rebuilt,
  // unless the release is already public (then it cannot be replaced and verifyPrepared rejects it).
  if (present && !releaseExists && !clean) rmSync(releaseDirectory, { recursive: true, force: true })
  const output = existsSync(releaseDirectory) ? releaseDirectory : await packageRelease({ notes })
  const release = JSON.parse(readFileSync(path.join(output, 'release.json'), 'utf8'))
  if (release.version !== version) throw new Error(`${output} was prepared for a different version; remove it to rebuild`)
  const prepared = verifyPrepared({ output, version, notes, publicEDKey, currentFeed: feedText, appTreeHash, head })
  // Safe order: 1) public release asset, 2) verify the public download, 3) signed feed commit.
  if (!releaseExists) gh('release', 'create', tag, prepared.archive, '--repo', defaults.repository, '--target', head, '--title', `OMP Usage ${version}`, '--notes', notes)
  const download = path.join(output, `download-check${path.extname(prepared.archive)}`)
  run('/usr/bin/curl', ['--fail', '--location', '--proto', '=https', '--silent', '--show-error', '--output', download, prepared.url])
  if (sha256File(download) !== prepared.sha256) throw new Error('Published asset differs from the prepared archive; feed NOT updated')
  rmSync(download)
  verifyFeed(path.join(output, 'appcast.xml'), publicEDKey)
  writeFileSync(feedPath, readFileSync(path.join(output, 'appcast.xml')))
  git('add', 'updates/appcast.xml')
  git('commit', '-m', `Publish OMP Usage ${version} update feed`)
  git('push', 'origin', 'HEAD:main')
  console.log(JSON.stringify({ published: version, release: `https://github.com/${defaults.repository}/releases/tag/${tag}` }, null, 2))
}

/**
 * Feed text containing only the kept release item, byte-for-byte as it appears in `feedText` (callers verify its signature first).
 * The kept release must be the newest one so no newer release can be dropped.
 * @param {string} feedText @param {string} keepVersion
 * @returns {{text: string, kept: string, removed: string[]}}
 */
export function prunedFeed(feedText, keepVersion) {
  const items = feedItems(feedText), kept = items.find(item => itemVersion(item) === keepVersion)
  if (!kept) throw new Error(`Signed feed has no item for version ${keepVersion}`)
  const newer = items.filter(item => compareVersions(itemVersion(item), keepVersion) > 0)
  if (newer.length) throw new Error(`Refusing to prune: the feed contains newer versions (${newer.map(itemVersion).join(', ')})`)
  const text = renderFeed([kept])
  if (feedItems(text).length !== 1 || feedItems(text)[0] !== kept) throw new Error('Pruned feed did not retain the kept item exactly')
  return { text, kept, removed: items.filter(item => item !== kept).map(itemVersion) }
}

/**
 * Signed feed maintenance after a release is public: retains only `keepVersion` in the feed. Never deletes GitHub releases or tags.
 * Refuses unless the kept item's public asset (length, Ed25519 signature, DMG layout, universal app, version, tree hash) and the live feed verify.
 * @param {{keepVersion: string, dryRun: boolean}} options
 */
async function prune({ keepVersion, dryRun }) {
  if (!/^\d+\.\d+\.\d+$/.test(keepVersion)) throw new Error(`--keep-version must be MAJOR.MINOR.PATCH, got ${JSON.stringify(keepVersion)}`)
  const { appTreeHash } = await import('./ownership.mjs')
  const channel = readChannel(), publicEDKey = channel.publicEDKey
  requireCleanMain({ dryRun, dirty: 'Working tree must be clean before pruning', branch: 'Prune from the main branch' })
  const localFeed = verifyFeed(feedPath, publicEDKey), { text: candidate, kept, removed } = prunedFeed(localFeed, keepVersion)
  const live = run('/usr/bin/curl', ['--fail', '--location', '--proto', '=https', '--silent', '--show-error', channel.feedURL])
  verifyFeedText(live, publicEDKey, channel.feedURL)
  if (live !== localFeed) throw new Error('The live feed differs from the committed feed (the raw-content cache can lag a few minutes after a push); retry later')
  const parsed = parseItem(kept)
  if (parsed.url !== downloadURL(keepVersion)) throw new Error('Kept feed item does not point at the DMG release asset')
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-release-prune-'))
  try {
    const asset = path.join(directory, archiveName(keepVersion))
    run('/usr/bin/curl', ['--fail', '--location', '--proto', '=https', '--silent', '--show-error', '--output', asset, parsed.url])
    verifyReleaseAsset({ file: asset, item: parsed, version: keepVersion, publicEDKey, appTreeHash })
    if (!removed.length) { console.log(JSON.stringify({ pruned: false, keep: keepVersion, note: 'Feed already contains only the kept release; live feed and public asset verified' }, null, 2)); return }
    if (dryRun) { console.log(JSON.stringify({ dryRun: true, keep: keepVersion, remove: removed, note: 'Live feed and public asset verified; nothing was written, committed or pushed' }, null, 2)); return }
    const original = readFileSync(feedPath)
    try {
      writeFileSync(feedPath, candidate)
      signFeed(ensureSparkleSdk(), feedPath, publicEDKey)
      const signed = verifyFeed(feedPath, publicEDKey), items = feedItems(signed)
      if (items.length !== 1 || items[0] !== kept) throw new Error('Signed pruned feed does not retain exactly the kept item')
    } catch (error) { writeFileSync(feedPath, original); throw error }
    git('add', 'updates/appcast.xml')
    git('commit', '-m', `Prune OMP Usage update feed to ${keepVersion}`)
    git('push', 'origin', 'HEAD:main')
    const pushed = git('rev-parse', 'HEAD')
    if (git('ls-remote', 'origin', 'refs/heads/main').split(/\s+/)[0] !== pushed) throw new Error('origin/main does not equal the pruned feed commit')
    console.log(JSON.stringify({ pruned: true, keep: keepVersion, removed, commit: pushed, note: 'GitHub releases and tags were not touched' }, null, 2))
  } finally { rmSync(directory, { recursive: true, force: true }) }
}

/**
 * @param {string[]} args @param {Record<string, 'value'|'switch'>} flags
 * @returns {{values: Map<string, string>, switches: Set<string>}}
 */
function parse(args, flags) {
  const values = /** @type {Map<string, string>} */ (new Map()), switches = /** @type {Set<string>} */ (new Set())
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? '', name = arg.replace(/^--/, ''), kind = arg.startsWith('--') ? flags[name] : undefined
    if (!kind) throw new Error(usage)
    if (kind === 'switch') switches.add(name)
    else { const value = args[++i]; if (value === undefined) throw new Error(usage); values.set(name, value) }
  }
  return { values, switches }
}
if (import.meta.main) {
  const [command, ...args] = process.argv.slice(2)
  if (command === 'setup') setup({ publicKey: parse(args, { 'public-key': 'value' }).values.get('public-key') })
  else if (command === 'package') {
    const { values } = parse(args, { output: 'value', 'notes-file': 'value', 'ci-run': 'value' }), notesFile = values.get('notes-file')
    console.log(await packageRelease({ outputDirectory: values.get('output'), notes: notesFile ? readFileSync(path.resolve(notesFile), 'utf8').trim() : undefined, ciRun: values.get('ci-run') }))
  } else if (command === 'publish') {
    const { values, switches } = parse(args, { 'notes-file': 'value', 'dry-run': 'switch' }), notesFile = values.get('notes-file')
    if (!notesFile) throw new Error(usage)
    await publish({ notesFile, dryRun: switches.has('dry-run') })
  } else if (command === 'prune') {
    const { values, switches } = parse(args, { 'keep-version': 'value', 'dry-run': 'switch' }), keepVersion = values.get('keep-version')
    if (!keepVersion) throw new Error(usage)
    await prune({ keepVersion, dryRun: switches.has('dry-run') })
  } else throw new Error(usage)
}
