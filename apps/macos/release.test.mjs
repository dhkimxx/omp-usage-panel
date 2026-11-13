import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash, generateKeyPairSync } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { appendFileSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { DmgCleanupError, createDmg, dmgAppName, dmgNote, dmgNoteName } from './dmg.mjs'
import { appTreeHash } from './ownership.mjs'
import { archiveName, createPreparedPackage, downloadURL, emptyFeed, feedItems, inspectArchive, parseItem, prepareArchive, prepareFromCandidate, prunedFeed, removeTemporaryTree, verifyFeedText, verifyPrepared, verifyReleaseAsset, withTemporaryDirectory } from './release.mjs'
import { buildFixtureApp, fixtureNodePin, inTemp, recordingHdiutil, signerFor } from './release-fixtures.mjs'
import { verifyNodeResources } from './sparkle.mjs'

// Real consumer boundaries: a universal ad-hoc-signed fixture app, a real compressed DMG attached read-only through hdiutil,
// and Ed25519 signatures verified by the production code. Only the Keychain-backed signer is replaced by an in-process key.
// Needs a host that may attach disk images and has the Xcode command line tools.
const darwin = { skip: process.platform !== 'darwin' }
const version = '1.0.0', head = 'a'.repeat(40), notes = '## OMP Usage Panel 1.0.0\n\nOfficial release.'
const { privateKey, publicKey } = generateKeyPairSync('ed25519')
const publicEDKey = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64')
const otherKey = generateKeyPairSync('ed25519').privateKey

/** @typedef {ReturnType<typeof signerFor>} TestSigner */
/** @type {TestSigner} */
const signer = signerFor(privateKey)
/** Re-signs `file` after replacing its content, like an attacker holding a trusted key would. @param {string} file @param {string} unsignedText @param {TestSigner} [signWith] */
function resign(file, unsignedText, signWith = signer) { writeFileSync(file, unsignedText); signWith.signFeed(file) }
/** @param {string} feed */
const unsigned = feed => feed.slice(0, feed.lastIndexOf('<!-- sparkle-signatures:'))

const legacyItem = `<item>
      <title>OMP Usage 0.2.1</title>
      <pubDate>Thu, 12 Nov 2026 06:20:25 +0000</pubDate>
      <sparkle:version>0.2.1</sparkle:version>
      <sparkle:shortVersionString>0.2.1</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <omp:appTreeSHA256>${'5'.repeat(64)}</omp:appTreeSHA256>
      <description sparkle:descriptionFormat="plain-text"><![CDATA[legacy notes]]></description>
      <enclosure url="https://github.com/dhkimxx/omp-usage-panel/releases/download/v0.2.1/OMP-Usage-0.2.1.zip" length="2598606" type="application/octet-stream" sparkle:edSignature="AAAA" />
    </item>`
// The deployed feed carries ZIP-era items; a candidate must extend it verbatim.
const currentFeed = emptyFeed().replace('  </channel>', `    ${legacyItem}\n  </channel>`)

/**
 * @param {string} directory @param {{app?: string, sourceCommit?: string|undefined, name?: string, packageNotes?: string}} [options]
 * @returns {string} prepared package directory
 */
function prepare(directory, options = {}) {
  const { app = buildFixtureApp(directory), name = 'package', packageNotes = notes } = options
  // An explicit `sourceCommit: undefined` means "no provenance claim"; only an absent key defaults to the pinned head.
  const sourceCommit = 'sourceCommit' in options ? options.sourceCommit : head
  const stage = path.join(directory, name)
  mkdirSync(stage)
  createPreparedPackage({ app, stage, version, notes: packageNotes, sourceCommit, currentFeed, appTreeHash, signer, pubDate: 'Thu, 12 Nov 2026 07:00:00 +0000', nodePin: fixtureNodePin })
  return stage
}
/** @param {string} output @param {Partial<Parameters<typeof verifyPrepared>[0]>} [overrides] */
const verify = (output, overrides = {}) => verifyPrepared({ output, version, notes, publicEDKey, currentFeed, appTreeHash, head, nodePin: fixtureNodePin, ...overrides })
/** Replaces text in the signed candidate feed and signs it again with `signWith`. @param {string} output @param {(feed: string) => string} mutate @param {TestSigner} [signWith] */
function rewriteFeed(output, mutate, signWith = signer) {
  const file = path.join(output, 'appcast.xml')
  resign(file, mutate(unsigned(readFileSync(file, 'utf8'))), signWith)
}
/** A hand-made image with the right app but extra visible payload, signed and listed as if it were the release. @param {string} directory @param {string} output @param {string} app @param {(stage: string) => void} extra */
function replaceDmgPayload(directory, output, app, extra) {
  const stage = mkdtempSync(path.join(directory, 'forged-'))
  execFileSync('/usr/bin/ditto', [app, path.join(stage, dmgAppName)])
  writeFileSync(path.join(stage, dmgNoteName), dmgNote)
  extra(stage)
  const dmg = path.join(output, archiveName(version))
  rmSync(dmg)
  execFileSync('/usr/bin/hdiutil', ['create', '-quiet', '-srcfolder', stage, '-volname', 'OMP Usage', '-fs', 'HFS+', '-format', 'UDZO', dmg])
  const { signature, length } = signer.signArchive(dmg)
  // Only the new release's enclosure changes; the legacy ZIP item keeps its original attributes.
  rewriteFeed(output, feed => feed.replace(/length="\d+" type="application\/octet-stream" sparkle:edSignature="[^"]+"/g, match => match.includes('"AAAA"') ? match : `length="${length}" type="application/octet-stream" sparkle:edSignature="${signature}"`))
}

test('a prepared DMG package verifies end to end against its signed feed and the mounted app', darwin, () => inTemp(directory => {
  const app = buildFixtureApp(directory), output = prepare(directory, { app })
  const dmg = path.join(output, archiveName(version)), prepared = verify(output)
  assert.equal(prepared.url, downloadURL(version))
  assert.equal(prepared.archive, dmg)
  assert.equal(prepared.sha256, createHash('sha256').update(readFileSync(dmg)).digest('hex'))
  const feed = verifyFeedText(readFileSync(path.join(output, 'appcast.xml'), 'utf8'), publicEDKey, 'candidate'), items = feedItems(feed)
  assert.equal(items.length, 2); assert.equal(items[0], legacyItem, 'existing ZIP-era items are carried over byte for byte')
  const item = parseItem(items[1])
  assert.equal(item.appTreeSHA256, appTreeHash(app)); assert.equal(item.length, readFileSync(dmg).length); assert.equal(item.sourceCommit, head)
}))

test('signed asset tampering is rejected before the image is trusted', darwin, () => inTemp(directory => {
  const output = prepare(directory), dmg = path.join(output, archiveName(version)), original = readFileSync(dmg)
  const flipped = Buffer.from(original); flipped[Math.floor(flipped.length / 2)] ^= 0xff
  writeFileSync(dmg, flipped)
  assert.throws(() => verify(output), /signature does not verify/)
  writeFileSync(dmg, Buffer.concat([original, Buffer.from([0])]))
  assert.throws(() => verify(output), /length differs/)
  writeFileSync(dmg, original)
  assert.equal(verify(output).archive, dmg, 'restoring the exact bytes verifies again')
}))

test('prepared feed provenance, URL, notes, hash, key and ancestry mismatches are rejected', darwin, () => inTemp(directory => {
  const app = buildFixtureApp(directory)
  assert.throws(() => verify(prepare(directory, { app, name: 'nocommit', sourceCommit: undefined })), /clean pinned HEAD/, 'a package built without a clean-commit claim')
  const output = prepare(directory, { app })
  assert.throws(() => verify(output, { head: 'b'.repeat(40) }), /clean pinned HEAD/)
  assert.throws(() => verify(output, { notes: 'other notes' }), /notes differ/)
  assert.throws(() => verify(output, { currentFeed: emptyFeed() }), /does not extend/)
  assert.throws(() => verify(output, { publicEDKey: generateKeyPairSync('ed25519').publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64') }), /signature does not verify/)

  const feedFile = path.join(output, 'appcast.xml'), good = readFileSync(feedFile, 'utf8')
  /** Every permutation starts from the pristine signed feed, so one case can never influence the next. @param {() => void} mutation @param {RegExp} expected @param {string} label */
  const rejects = (mutation, expected, label) => {
    writeFileSync(feedFile, good)
    mutation()
    assert.throws(() => verify(output), expected, label)
  }
  rejects(() => rewriteFeed(output, feed => feed.replace('/v1.0.0/OMP-Usage-1.0.0.dmg', '/v1.0.0/OMP-Usage-1.0.0.zip')), /enclosure URL/, 'a ZIP URL for the same version')
  rejects(() => rewriteFeed(output, feed => feed.replace('/v1.0.0/OMP-Usage-1.0.0.dmg', '/v0.9.9/OMP-Usage-0.9.9.dmg')), /enclosure URL/, 'another version URL')
  rejects(() => rewriteFeed(output, feed => feed.replace(/<omp:appTreeSHA256>([a-f0-9]{64})<\/omp:appTreeSHA256>(\s*<omp:sourceCommit>)/, `<omp:appTreeSHA256>${'0'.repeat(64)}</omp:appTreeSHA256>$2`)), /tree hash differs/, 'a different signed tree hash')
  rejects(() => rewriteFeed(output, feed => feed, signerFor(otherKey)), /signature does not verify/, 'a feed signed with another key is not trusted')
  rejects(() => writeFileSync(feedFile, unsigned(good)), /not signed/, 'an unsigned feed')
  writeFileSync(feedFile, good)
  assert.equal(verify(output).url, downloadURL(version), 'the pristine feed verifies again')
}))

test('an app whose Info.plist version differs from the release version is rejected', darwin, () => inTemp(directory => {
  const output = prepare(directory, { app: buildFixtureApp(directory, { version: '0.9.0' }) })
  assert.throws(() => verify(output), /app version 0\.9\.0 differs from 1\.0\.0/)
}))

test('packaging rejects an app that is not universal or whose deep signature is broken', darwin, () => inTemp(directory => {
  assert.throws(() => prepare(directory, { app: buildFixtureApp(directory, { universal: false }), name: 'thin' }), /not universal/)
  const app = buildFixtureApp(directory, { version: '1.0.0' })
  appendFileSync(path.join(app, 'Contents/Resources/data.txt'), 'tampered after signing')
  assert.throws(() => prepare(directory, { app, name: 'broken' }), /codesign/)
}))

test('a signed DMG with an extra app, an Applications link or an extra file is refused by the consumer check', darwin, () => inTemp(directory => {
  const app = buildFixtureApp(directory)
  for (const [label, extra] of /** @type {[string, (stage: string) => void][]} */ ([
    ['extra app', stage => execFileSync('/usr/bin/ditto', [path.join(stage, dmgAppName), path.join(stage, 'Second.app')])],
    ['Applications link', stage => execFileSync('/bin/ln', ['-s', '/Applications', path.join(stage, 'Applications')])],
    ['extra file', stage => writeFileSync(path.join(stage, 'README.txt'), 'x')],
  ])) {
    const output = prepare(directory, { app, name: `forged-${label.replace(/\s/g, '-')}` })
    replaceDmgPayload(directory, output, app, extra)
    assert.throws(() => verify(output), /DMG must contain exactly/, label)
  }
}))

test('pruning keeps exactly the signed kept item and verifies the retained public asset', darwin, () => inTemp(directory => {
  const output = prepare(directory), asset = path.join(output, archiveName(version))
  const candidate = readFileSync(path.join(output, 'appcast.xml'), 'utf8'), kept = feedItems(candidate)[1]
  const { text, removed } = prunedFeed(candidate, version)
  assert.deepEqual(removed, ['0.2.1'])
  assert.deepEqual(feedItems(text), [kept])
  assert.equal(text.includes('0.2.1'), false)
  const file = path.join(directory, 'pruned.xml'); resign(file, text)
  assert.equal(feedItems(verifyFeedText(readFileSync(file, 'utf8'), publicEDKey, file))[0], kept, 'the re-signed feed retains the kept item unchanged')
  assert.deepEqual(prunedFeed(text, version).removed, [], 'pruning an already pruned feed removes nothing')
  assert.throws(() => prunedFeed(candidate, '1.0.1'), /no item for version 1\.0\.1/)
  assert.throws(() => prunedFeed(candidate, '0.2.1'), /newer versions \(1\.0\.0\)/)
  const item = parseItem(kept)
  assert.equal(verifyReleaseAsset({ file: asset, item, version, publicEDKey, appTreeHash }), createHash('sha256').update(readFileSync(asset)).digest('hex'))
  const truncated = path.join(directory, 'truncated.dmg')
  writeFileSync(truncated, readFileSync(asset).subarray(0, 4096))
  assert.throws(() => verifyReleaseAsset({ file: truncated, item, version, publicEDKey, appTreeHash }), /length differs/)
  const wrongHash = path.join(directory, 'copy.dmg'); copyFileSync(asset, wrongHash)
  assert.throws(() => verifyReleaseAsset({ file: wrongHash, item: { ...item, appTreeSHA256: '1'.repeat(64) }, version, publicEDKey, appTreeHash }), /tree hash differs/)
}))

test('an archive signed with another key is rejected before the image is ever attached; the right signature attaches it and verifies it', darwin, () => inTemp(directory => {
  const output = prepare(directory), asset = path.join(output, archiveName(version)), bytes = readFileSync(asset)
  const item = parseItem(/** @type {string} */ (feedItems(readFileSync(path.join(output, 'appcast.xml'), 'utf8')).at(-1)))
  // The same structurally valid image of the signed length: only the signing key differs from the trusted one.
  const hostile = { ...item, signature: signerFor(otherKey).signArchive(asset).signature }
  const refusal = recordingHdiutil()
  assert.throws(() => verifyReleaseAsset({ file: asset, item: hostile, version, publicEDKey, appTreeHash, hdiutil: refusal.hdiutil }))
  assert.deepEqual(refusal.attached, [], 'no image was attached before its signature was verified')
  const accepted = recordingHdiutil()
  assert.equal(verifyReleaseAsset({ file: asset, item, version, publicEDKey, appTreeHash, hdiutil: accepted.hdiutil }), createHash('sha256').update(bytes).digest('hex'))
  assert.deepEqual(accepted.attached, [asset], 'the correctly signed image was attached read-only exactly once and inspected')
}))

/** Re-seals the fixture app after a resource edit, so only the bundled Node check can object. @param {string} app */
const reseal = app => execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', app], { stdio: 'pipe' })

test('a newly built package refuses an app whose bundled Node is missing, inconsistent or tampered, even when the app is validly signed', darwin, () => inTemp(directory => {
  const app = buildFixtureApp(directory), resources = path.join(app, 'Contents/Resources/node')
  const manifestFile = path.join(resources, 'manifest.json'), archive = path.join(resources, 'node-x64.tar.xz')
  const manifest = readFileSync(manifestFile, 'utf8'), archiveBytes = readFileSync(archive)
  let attempt = 0
  /** @param {RegExp} expected @param {string} label */
  const refused = (expected, label) => {
    reseal(app)
    assert.throws(() => prepare(directory, { app, name: `refused-${attempt++}` }), expected, label)
  }
  const edited = JSON.parse(manifest)
  edited.arches.x64.archiveSize += 1
  writeFileSync(manifestFile, JSON.stringify(edited)); refused(/archive differs from its manifest/, 'manifest size does not match the archive')
  edited.arches.x64.archiveSize -= 1; edited.version = '0.0.1'
  writeFileSync(manifestFile, JSON.stringify(edited)); refused(/pinned/, 'manifest version is not the pinned one')
  edited.version = JSON.parse(manifest).version; edited.arches.x64.binarySHA256 = 'f'.repeat(64)
  writeFileSync(manifestFile, JSON.stringify(edited)); refused(/differs from the pin/, 'manifest binary identity is not the pinned one')
  writeFileSync(manifestFile, manifest); writeFileSync(archive, Buffer.concat([archiveBytes, Buffer.from([0])])); refused(/archive differs from its manifest/, 'archive bytes changed')
  writeFileSync(archive, archiveBytes); rmSync(archive); refused(/archive differs from its manifest/, 'archive missing')
  writeFileSync(archive, archiveBytes)
  // Self-consistent manifest and archive hash, but the `node` inside is not the pinned binary: only the content check can see it.
  const scratch = mkdtempSync(path.join(directory, 'poison-'))
  writeFileSync(path.join(scratch, 'node'), 'poisoned node\n', { mode: 0o755 }); writeFileSync(path.join(scratch, 'LICENSE'), 'license\n')
  execFileSync('/usr/bin/tar', ['-cJf', archive, '-C', scratch, 'node', 'LICENSE'], { env: { ...process.env, COPYFILE_DISABLE: '1' } })
  const poisoned = readFileSync(archive)
  edited.arches.x64.binarySHA256 = JSON.parse(manifest).arches.x64.binarySHA256
  edited.arches.x64.archiveSize = poisoned.length; edited.arches.x64.archiveSHA256 = createHash('sha256').update(poisoned).digest('hex')
  writeFileSync(manifestFile, JSON.stringify(edited)); refused(/node binary that differs from the pin/, 'archive holds other node bytes than the pin')
  reseal(app)
  assert.equal(verifyNodeResources(app, { required: true, matchPin: false }), true, 'without a pin comparison (published releases) the same resources are structurally fine')
  writeFileSync(manifestFile, manifest)
  writeFileSync(archive, archiveBytes); rmSync(resources, { recursive: true }); refused(/no bundled Node runtime/, 'no bundled Node at all')
  assert.deepEqual(readdirSync(path.join(directory, 'refused-0')), [], 'a refused package leaves no archive behind')
}))

test('an app built before Node was bundled still verifies as a published release, but is refused as a new build or CI candidate', darwin, () => inTemp(directory => {
  const app = buildFixtureApp(directory, { bundledNode: false })
  assert.throws(() => prepare(directory, { app, name: 'new-build' }), /no bundled Node runtime/)
  const stage = path.join(directory, 'old-release'); mkdirSync(stage)
  const archive = createDmg({ app, output: path.join(stage, archiveName(version)) })
  prepareArchive({ archive, version, notes, sourceCommit: head, currentFeed, signer, pubDate: 'Thu, 12 Nov 2026 07:00:00 +0000', inspect: file => inspectArchive({ file, version, appTreeHash }) })
  const item = parseItem(/** @type {string} */ (feedItems(readFileSync(path.join(stage, 'appcast.xml'), 'utf8')).at(-1)))
  assert.equal(verifyReleaseAsset({ file: archive, item, version, publicEDKey, appTreeHash }), sha256Of(archive), 'a published release without node resources keeps verifying')
  assert.throws(() => verifyReleaseAsset({ file: archive, item, version, publicEDKey, appTreeHash, requireBundledNode: true }), /no bundled Node runtime/)
  assert.throws(() => verify(stage), /no bundled Node runtime/, 'publishing refuses a package without the bundled runtime')
  const candidateStage = path.join(directory, 'candidate-stage'); mkdirSync(candidateStage)
  const candidate = { archivePath: archive, sha256: sha256Of(archive), manifest: { sourceCommit: head, appTreeSHA256: appTreeHash(app) }, provenance: {} }
  const spy = { signed: /** @type {string[]} */ ([]), signArchive: (/** @type {string} */ file) => { spy.signed.push(file); return signer.signArchive(file) }, signFeed: signer.signFeed }
  assert.throws(() => prepareFromCandidate({ candidate, stage: candidateStage, version, notes, currentFeed, appTreeHash, signer: spy }), /no bundled Node runtime/)
  assert.deepEqual(spy.signed, [], 'a CI candidate without the bundled runtime is never signed')
}))

test('from the first bundled version on, a published release must carry structurally valid node resources; its manifest is not compared with the current pin', darwin, () => inTemp(directory => {
  const stage = path.join(directory, 'stage'); mkdirSync(stage)
  /** @param {string} appVersion @param {boolean} bundledNode */
  const publish = (appVersion, bundledNode) => {
    const app = buildFixtureApp(directory, { version: appVersion, bundledNode })
    const archive = createDmg({ app, output: path.join(stage, archiveName(appVersion)) })
    prepareArchive({ archive, version: appVersion, notes, sourceCommit: head, currentFeed, signer, pubDate: 'Thu, 12 Nov 2026 07:00:00 +0000', inspect: () => appTreeHash(app) })
    return { archive, item: parseItem(/** @type {string} */ (feedItems(readFileSync(path.join(stage, 'appcast.xml'), 'utf8')).at(-1))) }
  }
  const missing = publish('1.1.0', false)
  assert.throws(() => verifyReleaseAsset({ file: missing.archive, item: missing.item, version: '1.1.0', publicEDKey, appTreeHash }), /no bundled Node runtime/)
  rmSync(path.join(stage, 'appcast.xml')); rmSync(path.join(stage, 'release.json'))
  // The fixtures' binary identity is not the committed pin's (as after a later pin bump): the published release still verifies.
  const present = publish('1.1.1', true)
  assert.equal(verifyReleaseAsset({ file: present.archive, item: present.item, version: '1.1.1', publicEDKey, appTreeHash }), sha256Of(present.archive))
}))

// ---- CI candidate promotion: the DMG bytes GitHub built and attested are the bytes that get signed.
/** @param {string} file */
const sha256Of = file => createHash('sha256').update(readFileSync(file)).digest('hex')
/** @typedef {Parameters<typeof prepareFromCandidate>[0]['candidate']} Candidate */
/**
 * An image built the way CI builds it. Compressed images are not reproducible, so this one file is the only authority for "the bytes".
 * @param {string} directory @param {{app?: string, name?: string, manifestTree?: string}} [options]
 * @returns {Candidate}
 */
function ciCandidate(directory, { app = buildFixtureApp(directory), name = 'candidate', manifestTree = appTreeHash(app) } = {}) {
  const folder = path.join(directory, name); mkdirSync(folder)
  const archive = createDmg({ app, output: path.join(folder, archiveName(version)) })
  return { archivePath: archive, sha256: sha256Of(archive), manifest: { sourceCommit: head, appTreeSHA256: manifestTree }, provenance: { runId: '4242', runAttempt: 1, event: 'workflow_dispatch', ref: 'refs/heads/main' } }
}
/** A signer that records the digest of every archive it is asked to sign. */
function spySigner() {
  /** @type {string[]} */
  const signed = []
  /** @param {string} file */
  const signArchive = file => { signed.push(sha256Of(file)); return signer.signArchive(file) }
  return { signed, signArchive, signFeed: signer.signFeed }
}

test('a CI candidate is signed as the exact attested bytes and then passes the normal publish verification', darwin, () => inTemp(directory => {
  const candidate = ciCandidate(directory), original = readFileSync(candidate.archivePath)
  const stage = path.join(directory, 'package'); mkdirSync(stage)
  const spy = spySigner()
  const prepared = prepareFromCandidate({ candidate, stage, version, notes, currentFeed, appTreeHash, signer: spy, pubDate: 'Thu, 12 Nov 2026 07:00:00 +0000', nodePin: fixtureNodePin })
  const archive = path.join(stage, archiveName(version))
  assert.ok(readFileSync(archive).equals(original), 'the staged DMG is byte-identical to the authenticated candidate, not a rebuild')
  assert.deepEqual(spy.signed, [candidate.sha256], 'the update signature was made over exactly the authenticated bytes')
  assert.equal(prepared.sha256, candidate.sha256)
  assert.equal(prepared.appTreeSHA256, candidate.manifest.appTreeSHA256)
  const verified = verify(stage)
  assert.equal(verified.sha256, candidate.sha256, 'the publish-time verification accepts the promoted package')
  assert.equal(verified.url, downloadURL(version))
  const record = JSON.parse(readFileSync(path.join(stage, 'release.json'), 'utf8'))
  assert.equal(record.archiveSHA256, candidate.sha256); assert.equal(record.sourceCommit, head); assert.equal(record.ci.runId, '4242')
  const item = parseItem(/** @type {string} */ (feedItems(readFileSync(path.join(stage, 'appcast.xml'), 'utf8')).at(-1)))
  assert.equal(item.sourceCommit, head); assert.equal(item.length, original.length)
  assert.ok(readFileSync(candidate.archivePath).equals(original), 'the downloaded candidate itself is never modified')
  assert.throws(() => verify(stage, { head: 'b'.repeat(40) }), 'a package promoted for another commit cannot be published from this checkout')
}))

test('a CI candidate that fails inspection or differs from the authenticated bytes is refused before anything is signed', darwin, () => inTemp(directory => {
  const app = buildFixtureApp(directory)
  /** @param {Candidate} candidate @param {string} label */
  const refused = (candidate, label) => {
    const stage = mkdtempSync(path.join(directory, 'stage-')), spy = spySigner()
    assert.throws(() => prepareFromCandidate({ candidate, stage, version, notes, currentFeed, appTreeHash, signer: spy, nodePin: fixtureNodePin }), label)
    assert.deepEqual(spy.signed, [], `${label}: the signing key was never used`)
    assert.deepEqual(readdirSync(stage), [archiveName(version)], `${label}: no feed or release record was produced`)
  }
  refused(ciCandidate(directory, { app, name: 'wrong-tree', manifestTree: '0'.repeat(64) }), 'a manifest tree hash that is not the image\'s')
  refused(ciCandidate(directory, { app: buildFixtureApp(directory, { version: '0.9.0' }), name: 'wrong-version' }), 'an app of another version')
  refused(ciCandidate(directory, { app: buildFixtureApp(directory, { universal: false }), name: 'thin' }), 'a single-architecture app')
  const swapped = ciCandidate(directory, { app, name: 'swapped' }); appendFileSync(swapped.archivePath, Buffer.from([0]))
  refused(swapped, 'bytes that changed after authentication')
  const folder = path.join(directory, 'extra'), payload = mkdtempSync(path.join(directory, 'payload-')), extra = path.join(folder, archiveName(version))
  mkdirSync(folder)
  execFileSync('/usr/bin/ditto', [app, path.join(payload, dmgAppName)]); writeFileSync(path.join(payload, dmgNoteName), dmgNote); writeFileSync(path.join(payload, 'README.txt'), 'x')
  execFileSync('/usr/bin/hdiutil', ['create', '-quiet', '-srcfolder', payload, '-volname', 'OMP Usage', '-fs', 'HFS+', '-format', 'UDZO', extra])
  refused({ archivePath: extra, sha256: sha256Of(extra), manifest: { sourceCommit: head, appTreeSHA256: appTreeHash(app) }, provenance: {} }, 'an extra file in the image')
  const stage = mkdtempSync(path.join(directory, 'stage-')), good = ciCandidate(directory, { app, name: 'good' })
  /** @param {string} file */
  const rewriteAndSign = file => { appendFileSync(file, Buffer.from([0])); return signer.signArchive(file) }
  const rewriting = { signArchive: rewriteAndSign, signFeed: signer.signFeed }
  assert.throws(() => prepareFromCandidate({ candidate: good, stage, version, notes, currentFeed, appTreeHash, signer: rewriting, nodePin: fixtureNodePin }), 'a signer that rewrites the archive')
}))

test('temporary cleanup never reaches into a mounted volume and never follows links', darwin, () => inTemp(directory => {
  const dmg = createDmg({ app: buildFixtureApp(directory), output: path.join(directory, 'volume.dmg') })
  const scratch = path.join(directory, 'scratch'), mount = path.join(scratch, 'mount'), outside = path.join(directory, 'outside')
  mkdirSync(mount, { recursive: true }); mkdirSync(outside); writeFileSync(path.join(outside, 'keep.txt'), 'keep')
  symlinkSync(outside, path.join(scratch, 'link'))
  execFileSync('/usr/bin/hdiutil', ['attach', '-quiet', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, dmg])
  try {
    assert.throws(() => removeTemporaryTree(scratch), 'removal stops at a mounted volume')
    assert.equal(readFileSync(path.join(mount, dmgNoteName), 'utf8'), dmgNote, 'the mounted volume was not touched')
  } finally { execFileSync('/usr/bin/hdiutil', ['detach', '-quiet', mount]) }
  removeTemporaryTree(scratch)
  assert.equal(existsSync(scratch), false, 'once nothing is mounted the tree is removed')
  assert.equal(readFileSync(path.join(outside, 'keep.txt'), 'utf8'), 'keep', 'a link is removed, its target is never followed')
  removeTemporaryTree(scratch)
}))

test('withTemporaryDirectory removes its directory unless a DMG detach is uncertain and never hides the original failure', () => inTemp(directory => {
  let seen = ''
  const failure = new Error('original operation failed')
  assert.throws(() => withTemporaryDirectory(directory, 'a-', created => { seen = created; writeFileSync(path.join(created, 'x'), '1'); throw failure }), error => error === failure)
  assert.equal(existsSync(seen), false)
  assert.throws(() => withTemporaryDirectory(directory, 'b-', created => { seen = created; throw new DmgCleanupError('detach uncertain', { devices: ['/dev/disk9'], mountPoint: '/x' }) }), DmgCleanupError)
  assert.equal(existsSync(seen), true, 'a directory whose image may still be attached is left in place')
  assert.equal(withTemporaryDirectory(directory, 'c-', created => { seen = created; return 7 }), 7)
  assert.equal(existsSync(seen), false)
  const moved = path.join(directory, 'moved')
  withTemporaryDirectory(directory, 'd-', created => renameSync(created, moved))
  assert.equal(existsSync(moved), true, 'a directory the body moved away is not touched')
}))
