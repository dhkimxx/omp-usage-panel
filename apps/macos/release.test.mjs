import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash, generateKeyPairSync, sign as cryptoSign } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { appendFileSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { dmgAppName, dmgNote, dmgNoteName } from './dmg.mjs'
import { appTreeHash } from './ownership.mjs'
import { archiveName, createPreparedPackage, downloadURL, emptyFeed, feedItems, parseItem, prunedFeed, verifyFeedText, verifyPrepared, verifyReleaseAsset } from './release.mjs'

// Real consumer boundaries: a universal ad-hoc-signed fixture app, a real compressed DMG attached read-only through hdiutil,
// and Ed25519 signatures verified by the production code. Only the Keychain-backed signer is replaced by an in-process key.
// Needs a host that may attach disk images and has the Xcode command line tools.
const darwin = { skip: process.platform !== 'darwin' }
const version = '1.0.0', head = 'a'.repeat(40), notes = '## OMP Usage Panel 1.0.0\n\nOfficial release.'
const { privateKey, publicKey } = generateKeyPairSync('ed25519')
const publicEDKey = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64')
const otherKey = generateKeyPairSync('ed25519').privateKey

/** @param {import('node:crypto').KeyObject} key */
function signerFor(key) {
  return {
    /** @param {string} file */
    signArchive(file) { const data = readFileSync(file); return { signature: cryptoSign(null, data, key).toString('base64'), length: data.length } },
    /** @param {string} file */
    signFeed(file) {
      const text = readFileSync(file, 'utf8'), data = Buffer.from(text)
      writeFileSync(file, `${text}<!-- sparkle-signatures:\nedSignature: ${cryptoSign(null, data, key).toString('base64')}\nlength: ${data.length}\n-->\n`)
    },
  }
}
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

/** Universal (arm64 + x86_64), ad-hoc deep-signed app. @param {string} directory @param {{version?: string, universal?: boolean}} [options] */
function buildFixtureApp(directory, { version: appVersion = version, universal = true } = {}) {
  const root = path.join(directory, `app-${appVersion}-${universal}`), app = path.join(root, dmgAppName)
  mkdirSync(path.join(app, 'Contents/MacOS'), { recursive: true })
  writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>OMPUsagePanel</string><key>CFBundleIdentifier</key><string>com.example.omp-usage-fixture</string><key>CFBundleName</key><string>OMP Usage</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>${appVersion}</string><key>CFBundleVersion</key><string>${appVersion}</string></dict></plist>\n`)
  const source = path.join(root, 'main.c')
  writeFileSync(source, 'int main(void) { return 0; }\n')
  execFileSync('/usr/bin/xcrun', ['clang', ...(universal ? ['-arch', 'arm64', '-arch', 'x86_64'] : ['-arch', process.arch === 'arm64' ? 'arm64' : 'x86_64']), '-o', path.join(app, 'Contents/MacOS/OMPUsagePanel'), source], { stdio: 'pipe' })
  rmSync(source)
  mkdirSync(path.join(app, 'Contents/Resources')); writeFileSync(path.join(app, 'Contents/Resources/data.txt'), 'resource')
  execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', app], { stdio: 'pipe' })
  return app
}

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
  createPreparedPackage({ app, stage, version, notes: packageNotes, sourceCommit, currentFeed, appTreeHash, signer, pubDate: 'Thu, 12 Nov 2026 07:00:00 +0000' })
  return stage
}
/** @param {string} output @param {Partial<Parameters<typeof verifyPrepared>[0]>} [overrides] */
const verify = (output, overrides = {}) => verifyPrepared({ output, version, notes, publicEDKey, currentFeed, appTreeHash, head, ...overrides })
/** @param {(directory: string) => void | Promise<void>} body */
async function inTemp(body) {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-release-test-'))
  try { await body(directory) } finally { rmSync(directory, { recursive: true, force: true }) }
}
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
