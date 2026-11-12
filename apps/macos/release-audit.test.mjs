import test, { after, before } from 'node:test'
import assert from 'node:assert/strict'
import { createHash, generateKeyPairSync, sign as cryptoSign } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { dmgAppName, dmgNote, dmgNoteName } from './dmg.mjs'
import { appTreeHash } from './ownership.mjs'
import { archiveName, createPreparedPackage, downloadURL, emptyFeed, feedItems } from './release.mjs'
import { assertCommitted, auditFeed, feedEntries, githubClient } from './release-audit.mjs'
import { channelPath, parseChannel } from './sparkle.mjs'

// The audit's consumer boundaries are real (universal ad-hoc-signed fixture apps, compressed DMGs attached read-only through hdiutil, Ed25519
// verified by the production code). Only GitHub and the download network are replaced by in-process doubles; nothing here touches the public network.
const darwin = { skip: process.platform !== 'darwin' }
const { privateKey, publicKey } = generateKeyPairSync('ed25519')
const publicEDKey = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64')
const otherKey = generateKeyPairSync('ed25519').privateKey
const commits = { '1.0.0': 'a'.repeat(40), '1.1.0': 'b'.repeat(40) }
const later = 'c'.repeat(40)

/** @param {import('node:crypto').KeyObject} key @param {string} text */
const signText = (key, text) => `${text}<!-- sparkle-signatures:\nedSignature: ${cryptoSign(null, Buffer.from(text), key).toString('base64')}\nlength: ${Buffer.byteLength(text)}\n-->\n`
/** @param {import('node:crypto').KeyObject} key */
function signerFor(key) {
  return {
    /** @param {string} file */
    signArchive(file) { const data = readFileSync(file); return { signature: cryptoSign(null, data, key).toString('base64'), length: data.length } },
    /** @param {string} file */
    signFeed(file) { writeFileSync(file, signText(key, readFileSync(file, 'utf8'))) },
  }
}
/** @param {string} feed */
const unsigned = feed => feed.slice(0, feed.lastIndexOf('<!-- sparkle-signatures:'))
/** @param {string} body @param {import('node:crypto').KeyObject} [key] */
const resigned = (body, key = privateKey) => signText(key, body)

/** @param {string} directory @param {string} version */
function buildFixtureApp(directory, version) {
  const root = path.join(directory, `app-${version}`), app = path.join(root, dmgAppName)
  mkdirSync(path.join(app, 'Contents/MacOS'), { recursive: true })
  writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>OMPUsagePanel</string><key>CFBundleIdentifier</key><string>com.example.omp-usage-fixture</string><key>CFBundleName</key><string>OMP Usage</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>${version}</string></dict></plist>\n`)
  const source = path.join(root, 'main.c')
  writeFileSync(source, 'int main(void) { return 0; }\n')
  execFileSync('/usr/bin/xcrun', ['clang', '-arch', 'arm64', '-arch', 'x86_64', '-o', path.join(app, 'Contents/MacOS/OMPUsagePanel'), source], { stdio: 'pipe' })
  rmSync(source)
  execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', app], { stdio: 'pipe' })
  return app
}

/** @typedef {{version: string, tag: string, url: string, sourceCommit: string, bytes: Buffer, sha256: string, app: string}} Built */
/** @type {{directory: string, feed: string, builds: Built[]}} */
let world
before(() => {
  if (process.platform !== 'darwin') return
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-audit-test-'))
  /** @type {Built[]} */
  const builds = []
  let feed = emptyFeed()
  for (const version of /** @type {const} */ (['1.0.0', '1.1.0'])) {
    const app = buildFixtureApp(directory, version), stage = path.join(directory, `package-${version}`)
    mkdirSync(stage)
    createPreparedPackage({ app, stage, version, notes: `OMP Usage ${version}`, sourceCommit: commits[version], currentFeed: feed, appTreeHash, signer: signerFor(privateKey), pubDate: 'Thu, 12 Nov 2026 07:00:00 +0000' })
    feed = readFileSync(path.join(stage, 'appcast.xml'), 'utf8')
    const bytes = readFileSync(path.join(stage, archiveName(version)))
    builds.push({ version, tag: `v${version}`, url: downloadURL(version), sourceCommit: commits[version], bytes, sha256: createHash('sha256').update(bytes).digest('hex'), app })
  }
  world = { directory, feed, builds }
})
after(() => { if (world) rmSync(world.directory, { recursive: true, force: true }) })

/** @param {Built} build */
const releaseJson = build => ({
  tag_name: build.tag, draft: false, prerelease: false, immutable: false, id: 42, published_at: '2026-11-12T10:18:25Z', target_commitish: 'main',
  html_url: `https://github.com/dhkimxx/omp-usage-panel/releases/tag/${build.tag}`,
  assets: [{ name: archiveName(build.version), state: 'uploaded', size: build.bytes.length, digest: `sha256:${build.sha256}`, browser_download_url: build.url }],
})

/**
 * In-process GitHub and download network, seeded with the honest public state; a test mutates the part it wants to break.
 * @param {{releases?: Record<string, any>, tags?: Record<string, string>, files?: Record<string, Buffer>}} [overrides]
 */
function network({ releases = {}, tags = {}, files = {} } = {}) {
  /** @type {string[]} */
  const calls = []
  const state = {
    releases: Object.fromEntries(world.builds.map(build => [build.tag, releaseJson(build)])),
    tags: Object.fromEntries(world.builds.map(build => [build.tag, build.sourceCommit])),
    files: Object.fromEntries(world.builds.map(build => [build.url, build.bytes])),
  }
  Object.assign(state.releases, releases); Object.assign(state.tags, tags); Object.assign(state.files, files)
  for (const [key, value] of Object.entries(state.releases)) if (value === null) delete state.releases[key]
  for (const [key, value] of Object.entries(state.tags)) if (value === '') delete state.tags[key]
  /** @type {import('./release-audit.mjs').GitHub} */
  const github = {
    release(tag) { calls.push(`release ${tag}`); const release = state.releases[tag]; if (!release) throw new Error('HTTP 404'); return structuredClone(release) },
    tagCommit(tag) { calls.push(`tag ${tag}`); const commit = state.tags[tag]; if (!commit) throw new Error('HTTP 404'); return commit },
  }
  /** @type {import('./release-audit.mjs').Download} */
  const download = (url, file, maxBytes) => {
    calls.push(`download ${url}`)
    const bytes = state.files[url]; if (!bytes) throw new Error('HTTP 404')
    writeFileSync(file, bytes.subarray(0, maxBytes + 1)) // like curl --max-filesize, one byte past the cap is observable
  }
  return { github, download, calls }
}
/** @param {ReturnType<typeof network>} net @param {string} [feedText] */
const audit = (net, feedText = world.feed) => auditFeed({ feedText, publicEDKey, github: net.github, download: net.download, appTreeHash })
/** @param {string} feedText @param {string} label */
function rejectedOffline(feedText, label) {
  const net = network()
  assert.throws(() => audit(net, feedText), Error, label)
  assert.deepEqual(net.calls, [], `${label}: rejected before any network access`)
}
/** The report entry of one version; fields of both the verified and the failed shape are read by the tests. @param {ReturnType<typeof audit>} report @param {string} version @returns {any} */
const entryFor = (report, version) => report.versions.find(entry => entry.version === version)

test('every signed version is verified against its real release, tag commit and public DMG bytes', darwin, () => {
  // GitHub's target_commitish is a branch name here and one release lacks a reported digest: neither may matter, the tag commit and signed bytes decide.
  const net = network({ releases: { 'v1.1.0': { ...releaseJson(/** @type {Built} */ (world.builds[1])), assets: [{ ...releaseJson(/** @type {Built} */ (world.builds[1])).assets[0], digest: null }] } } })
  const report = audit(net)
  assert.equal(report.ok, true)
  assert.equal(report.feedSHA256, createHash('sha256').update(world.feed).digest('hex'))
  assert.deepEqual(report.versions.map(entry => entry.version), ['1.0.0', '1.1.0'])
  for (const build of world.builds) {
    const entry = entryFor(report, build.version)
    assert.equal(entry.ok, true)
    assert.equal(entry.tagCommit, build.sourceCommit); assert.equal(entry.sourceCommit, build.sourceCommit)
    assert.equal(entry.asset.sha256, build.sha256); assert.equal(entry.asset.length, build.bytes.length); assert.equal(entry.asset.url, build.url)
    assert.equal(entry.appTreeSHA256, appTreeHash(build.app))
  }
  assert.equal(entryFor(report, '1.0.0').asset.githubDigest, 'matched'); assert.equal(entryFor(report, '1.1.0').asset.githubDigest, 'not-reported')
  assert.deepEqual(net.calls.filter(call => call.startsWith('download')), world.builds.map(build => `download ${build.url}`), 'only the canonical asset URLs are fetched')
})

test('a feed that is unsigned, mis-signed, tampered or malformed is refused before any network access', darwin, () => {
  const body = unsigned(world.feed), [first, second] = feedItems(body)
  rejectedOffline(body, 'unsigned feed')
  rejectedOffline(resigned(body, otherKey), 'signed by another key')
  rejectedOffline(world.feed.replace('OMP Usage 1.1.0', 'OMP Usage 9.9.9'), 'edited after signing')
  rejectedOffline(resigned(emptyFeed()), 'empty feed')
  rejectedOffline(resigned(body.replace(/<item>[\s\S]*<\/item>/, () => `${second}\n    ${first}`)), 'descending versions')
  rejectedOffline(resigned(body.replace(/(    <item>[\s\S]*<\/item>)/, (match) => `${match}\n    ${second}`)), 'duplicate version')
  for (const bad of ['1.1', '01.1.0', '1.1.0-rc.1', 'v1.1.0', '1.1.0 ']) {
    rejectedOffline(resigned(body.replace('<sparkle:version>1.1.0<', `<sparkle:version>${bad}<`).replace('<sparkle:shortVersionString>1.1.0<', `<sparkle:shortVersionString>${bad}<`)), `version ${JSON.stringify(bad)}`)
  }
  rejectedOffline(resigned(body.replace('<sparkle:shortVersionString>1.1.0<', '<sparkle:shortVersionString>1.1.1<')), 'short version differs')
  for (const url of [
    'https://github.com/someone-else/omp-usage-panel/releases/download/v1.1.0/OMP-Usage-1.1.0.dmg',
    'https://example.com/dhkimxx/omp-usage-panel/releases/download/v1.1.0/OMP-Usage-1.1.0.dmg',
    'http://github.com/dhkimxx/omp-usage-panel/releases/download/v1.1.0/OMP-Usage-1.1.0.dmg',
    `${downloadURL('1.1.0')}?download=1`,
    downloadURL('1.1.0').replace('.dmg', '.zip'),
    downloadURL('1.0.0'),
  ]) rejectedOffline(resigned(body.replace(`url="${downloadURL('1.1.0')}"`, `url="${url}"`)), `enclosure ${url}`)
  rejectedOffline(resigned(body.replace(/\s*<omp:sourceCommit>[a-f0-9]{40}<\/omp:sourceCommit>(?![\s\S]*<omp:sourceCommit>)/, '')), 'item without signed source commit')
})

test('a signed feed whose items are not what an RSS consumer sees is refused before any network access', darwin, () => {
  const body = unsigned(world.feed), second = /** @type {string} */ (feedItems(body)[1]), first = /** @type {string} */ (feedItems(body)[0])
  const sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle', omp = 'https://github.com/dhkimxx/omp-usage-panel/updates', other = 'https://example.com/other'
  const edit = (/** @type {string} */ search, /** @type {string} */ replacement) => { assert.ok(body.includes(search), search); return resigned(body.replace(search, () => replacement)) }
  rejectedOffline(edit(second, `<!-- ${second} -->`), 'the newest item commented out')
  rejectedOffline(edit('  </channel>', `    <!-- ${first} -->\n  </channel>`), 'a hidden extra item inside a comment')
  rejectedOffline(edit('</channel>', ''), 'unclosed channel')
  rejectedOffline(edit('version="2.0"', 'version="1.0"'), 'not RSS 2.0')
  rejectedOffline(edit('<rss', '<!DOCTYPE rss [<!ENTITY x "y">]>\n<rss'), 'DTD and entity declarations')
  rejectedOffline(edit(`xmlns:sparkle="${sparkle}"`, `xmlns:sparkle="${other}"`), 'the sparkle prefix bound to another namespace')
  rejectedOffline(edit(`xmlns:omp="${omp}"`, `xmlns:omp="${other}"`), 'the omp prefix bound to another namespace')
  rejectedOffline(edit('<sparkle:version>1.1.0</sparkle:version>', '<sparkle:version>1.1.0</sparkle:version><sparkle:version>1.1.0</sparkle:version>'), 'a duplicated version field')
  rejectedOffline(edit(`<omp:sourceCommit>${commits['1.1.0']}</omp:sourceCommit>`, `<!-- <omp:sourceCommit>${commits['1.1.0']}</omp:sourceCommit> -->`), 'a source commit visible to text matching only inside a comment')
  rejectedOffline(resigned(body.replace(second, () => '').replace('</channel>', () => `</channel>\n    ${second}`)), 'an item outside the channel')
})

test('release notes with CRLF or CR line endings, which an XML parser normalizes, do not make a valid signed feed ambiguous', darwin, () => {
  const feed = resigned(unsigned(world.feed).replace('<![CDATA[OMP Usage 1.1.0]]>', () => '<![CDATA[OMP Usage 1.1.0\r\n\r\nSecond\rThird]]>'))
  const entries = feedEntries(feed, publicEDKey)
  assert.deepEqual(entries.map(entry => entry.version), ['1.0.0', '1.1.0'])
  assert.equal(entries[1]?.item.notes, 'OMP Usage 1.1.0\r\n\r\nSecond\rThird')
})

test('the pinned channel is parsed from committed bytes and any other channel is refused', () => {
  const committed = readFileSync(channelPath)
  parseChannel(committed) // the unmodified committed channel must be acceptable, so each refusal below is caused by its mutation
  for (const mutate of /** @type {((value: Record<string, string>) => void)[]} */ ([
    value => { value.feedURL = 'https://raw.githubusercontent.com/someone-else/omp-usage-panel/main/updates/appcast.xml' },
    value => { value.account = 'other.account' },
    value => { value.namespace = 'https://example.com/updates' },
    value => { value.publicEDKey = 'AAAA' },
    value => { value.publicEDKey = Buffer.alloc(33, 1).toString('base64') },
  ])) {
    const value = JSON.parse(committed.toString('utf8')); mutate(value)
    assert.throws(() => parseChannel(JSON.stringify(value)), Error)
  }
})

test('a version whose GitHub release is not a stable, complete, single-DMG release fails without fetching it, and does not hide other versions', darwin, () => {
  const build = /** @type {Built} */ (world.builds[1]), good = releaseJson(build), asset = good.assets[0]
  /** @type {[string, any][]} */
  const cases = [
    ['draft', { ...good, draft: true }],
    ['prerelease', { ...good, prerelease: true }],
    ['a different release behind the tag', { ...good, tag_name: 'v1.0.0' }],
    ['an extra asset', { ...good, assets: [asset, { ...asset, name: 'OMP-Usage-1.1.0.zip' }] }],
    ['no asset', { ...good, assets: [] }],
    ['a wrongly named asset', { ...good, assets: [{ ...asset, name: 'OMP-Usage.dmg' }] }],
    ['an unfinished upload', { ...good, assets: [{ ...asset, state: 'starter' }] }],
    ['a different size', { ...good, assets: [{ ...asset, size: asset.size + 1 }] }],
    ['another download URL', { ...good, assets: [{ ...asset, browser_download_url: 'https://github.com/dhkimxx/omp-usage-panel/releases/download/v1.1.0/other.dmg' }] }],
    ['a malformed digest', { ...good, assets: [{ ...asset, digest: 'md5:abc' }] }],
    ['a missing release', null],
  ]
  for (const [label, release] of cases) {
    const net = network({ releases: { 'v1.1.0': release } }), report = audit(net), failed = entryFor(report, '1.1.0')
    assert.equal(report.ok, false, label)
    assert.equal(failed.ok, false, label); assert.equal(failed.stage, 'release', label)
    assert.equal(net.calls.some(call => call.includes(build.url)), false, `${label}: the asset is not downloaded`)
    assert.equal(entryFor(report, '1.0.0').ok, true, `${label}: the other version is still reported verified`)
  }
})

test('every version is audited: a failure never stops later versions and several failures are all reported', darwin, () => {
  const second = /** @type {Built} */ (world.builds[1])
  const firstFails = audit(network({ tags: { 'v1.0.0': later } }))
  assert.equal(firstFails.ok, false)
  assert.deepEqual(firstFails.versions.map(entry => [entry.version, entry.ok]), [['1.0.0', false], ['1.1.0', true]])
  assert.equal(entryFor(firstFails, '1.1.0').asset.sha256, second.sha256, 'the later version was fully verified after the earlier one failed')
  const both = audit(network({ tags: { 'v1.0.0': later }, releases: { 'v1.1.0': { ...releaseJson(second), draft: true } } }))
  assert.equal(both.ok, false)
  assert.deepEqual(both.versions.map(entry => [entry.version, entry.ok ? 'verified' : entry.stage]), [['1.0.0', 'tag'], ['1.1.0', 'release']])
})

test('the tag, not the release target or a later commit, must point at the signed source commit', darwin, () => {
  const build = /** @type {Built} */ (world.builds[1])
  for (const [label, tags, release] of /** @type {[string, Record<string, string>, any][]} */ ([
    ['tag moved to a later commit', { 'v1.1.0': later }, undefined],
    ['tag moved while target_commitish still names the signed commit', { 'v1.1.0': later }, { ...releaseJson(build), target_commitish: build.sourceCommit }],
    ['tag missing', { 'v1.1.0': '' }, undefined],
  ])) {
    const net = network({ tags, releases: release ? { 'v1.1.0': release } : {} }), failed = entryFor(audit(net), '1.1.0')
    assert.equal(failed.ok, false, label); assert.equal(failed.stage, 'tag', label)
    assert.equal(net.calls.some(call => call.startsWith('download') && call.includes('1.1.0')), false, `${label}: the asset is not downloaded`)
  }
})

test('public bytes that differ from the signed asset are refused before the image is mounted', darwin, () => {
  const build = /** @type {Built} */ (world.builds[1]), noDigest = { ...releaseJson(build), assets: [{ ...releaseJson(build).assets[0], digest: null }] }
  const flipped = Buffer.from(build.bytes); flipped[Math.floor(flipped.length / 2)] ^= 0xff
  const junk = Buffer.alloc(build.bytes.length, 7), longer = Buffer.concat([build.bytes, Buffer.from([0])])
  /** @type {[string, Record<string, any>, Buffer, string][]} */
  const cases = [
    ['flipped byte, GitHub digest still the original', {}, flipped, 'download'],
    ['flipped byte, no GitHub digest', { 'v1.1.0': noDigest }, flipped, 'asset'],
    ['same-length non-image bytes, no GitHub digest', { 'v1.1.0': noDigest }, junk, 'asset'],
    ['one byte too long', { 'v1.1.0': noDigest }, longer, 'download'],
    ['truncated', { 'v1.1.0': noDigest }, build.bytes.subarray(0, 4096), 'download'],
  ]
  for (const [label, releases, bytes, stage] of cases) {
    const failed = entryFor(audit(network({ releases, files: { [build.url]: bytes } })), '1.1.0')
    assert.equal(failed.ok, false, label); assert.equal(failed.stage, stage, label)
  }
  const digestLies = entryFor(audit(network({ releases: { 'v1.1.0': { ...releaseJson(build), assets: [{ ...releaseJson(build).assets[0], digest: `sha256:${'0'.repeat(64)}` }] } } })), '1.1.0')
  assert.equal(digestLies.ok, false); assert.equal(digestLies.stage, 'download')
})

test('a correctly signed feed item whose image or tree hash is wrong is still refused', darwin, () => {
  const build = /** @type {Built} */ (world.builds[1]), body = unsigned(world.feed)
  const wrongTree = entryFor(audit(network(), resigned(body.replace(/(<omp:appTreeSHA256>)[a-f0-9]{64}(<\/omp:appTreeSHA256>\s*<omp:sourceCommit>b)/, (_match, open, close) => `${open}${'0'.repeat(64)}${close}`))), '1.1.0')
  assert.equal(wrongTree.ok, false); assert.equal(wrongTree.stage, 'asset')

  // The trusted key signs an image with an extra visible file: layout is checked on the public bytes, not trusted because of the signature.
  const directory = mkdtempSync(path.join(world.directory, 'forged-'))
  const stage = path.join(directory, 'stage'), dmg = path.join(directory, archiveName(build.version))
  mkdirSync(stage)
  execFileSync('/usr/bin/ditto', [build.app, path.join(stage, dmgAppName)])
  writeFileSync(path.join(stage, dmgNoteName), dmgNote); writeFileSync(path.join(stage, 'README.txt'), 'extra')
  execFileSync('/usr/bin/hdiutil', ['create', '-quiet', '-srcfolder', stage, '-volname', 'OMP Usage', '-fs', 'HFS+', '-format', 'UDZO', dmg])
  const { signature, length } = signerFor(privateKey).signArchive(dmg)
  const forgedFeed = resigned(body.replace(new RegExp(`(url="${build.url}" length=")\\d+(" type="application/octet-stream" sparkle:edSignature=")[^"]+`), (_match, open, close) => `${open}${length}${close}${signature}`))
  const net = network({ releases: { 'v1.1.0': { ...releaseJson(build), assets: [{ ...releaseJson(build).assets[0], size: length, digest: null }] } }, files: { [build.url]: readFileSync(dmg) } })
  const report = audit(net, forgedFeed), failed = entryFor(report, '1.1.0')
  assert.equal(failed.ok, false); assert.equal(failed.stage, 'asset')
  assert.equal(entryFor(report, '1.0.0').ok, true, 'the untouched version still verifies')
})

test('the GitHub client resolves the tag object chain on the canonical repository and refuses anything that is not a commit', () => {
  const sha = (/** @type {string} */ c) => c.repeat(40)
  /** @param {Record<string, any>} routes */
  const clientFor = routes => githubClient({ api: apiPath => { const value = routes[apiPath]; if (!value) throw new Error(`HTTP 404 ${apiPath}`); return value } })
  const ref = 'repos/dhkimxx/omp-usage-panel/git/ref/tags/v1.0.0'
  const commit = { ref: 'refs/tags/v1.0.0', object: { type: 'commit', sha: sha('1') } }
  assert.equal(clientFor({ [ref]: commit }).tagCommit('v1.0.0'), sha('1'))
  const annotated = clientFor({
    [ref]: { ref: 'refs/tags/v1.0.0', object: { type: 'tag', sha: sha('2') } },
    [`repos/dhkimxx/omp-usage-panel/git/tags/${sha('2')}`]: { object: { type: 'tag', sha: sha('3') } },
    [`repos/dhkimxx/omp-usage-panel/git/tags/${sha('3')}`]: { object: { type: 'commit', sha: sha('4') } },
  })
  assert.equal(annotated.tagCommit('v1.0.0'), sha('4'), 'annotated tags are peeled to the commit')
  assert.throws(() => clientFor({ [ref]: { ...commit, ref: 'refs/tags/v1.0.0-rc' } }).tagCommit('v1.0.0'), Error, 'a different ref')
  assert.throws(() => clientFor({ [ref]: { ref: 'refs/tags/v1.0.0', object: { type: 'tree', sha: sha('5') } } }).tagCommit('v1.0.0'), Error, 'a tree')
  assert.throws(() => clientFor({ [ref]: { ref: 'refs/tags/v1.0.0', object: { type: 'commit', sha: 'abc' } } }).tagCommit('v1.0.0'), Error, 'a malformed sha')
  const loop = { ref: 'refs/tags/v1.0.0', object: { type: 'tag', sha: sha('6') } }
  assert.throws(() => clientFor({ [ref]: loop, [`repos/dhkimxx/omp-usage-panel/git/tags/${sha('6')}`]: { object: loop.object } }).tagCommit('v1.0.0'), Error, 'an endless annotated tag chain')
})

test('only feed and channel bytes identical to their blobs at HEAD are audited, even when git is told to hide the edit', darwin, () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-audit-git-'))
  try {
    /** @param {string[]} args */
    const git = args => execFileSync('/usr/bin/git', ['-C', directory, '-c', 'user.name=test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false', ...args], { encoding: 'utf8', stdio: 'pipe' }).trim()
    const feed = 'updates/appcast.xml', channel = 'channel.json', files = [feed, channel], at = (/** @type {string} */ name) => path.join(directory, name)
    git(['init', '-q'])
    mkdirSync(at('updates'))
    writeFileSync(at(feed), 'feed\n'); writeFileSync(at(channel), '{"publicEDKey":"pinned"}\n'); writeFileSync(at('untracked.xml'), 'x\n')
    git(['add', feed, channel]); git(['commit', '-q', '-m', 'init'])
    const head = git(['rev-parse', 'HEAD'])
    const committed = assertCommitted(directory, files)
    assert.equal(committed.commit, head)
    assert.deepEqual(committed.files[feed], Buffer.from('feed\n')); assert.deepEqual(committed.files[channel], Buffer.from('{"publicEDKey":"pinned"}\n'))
    assert.throws(() => assertCommitted(directory, ['untracked.xml']), Error, 'an untracked file')

    writeFileSync(at(feed), 'edited feed\n')
    assert.throws(() => assertCommitted(directory, files), Error, 'an edited feed')
    git(['add', feed])
    assert.throws(() => assertCommitted(directory, files), Error, 'a staged but uncommitted feed')
    git(['reset', '-q', '--', feed]); writeFileSync(at(feed), 'feed\n')

    for (const flag of ['assume-unchanged', 'skip-worktree']) {
      git(['update-index', `--${flag}`, channel])
      writeFileSync(at(channel), '{"publicEDKey":"attacker"}\n')
      assert.equal(git(['status', '--porcelain', '--untracked-files=no']), '', `git status is blind to the substituted pinned key under --${flag}`)
      assert.throws(() => assertCommitted(directory, files), Error, `a pinned key hidden with --${flag}`)
      git(['update-index', `--no-${flag}`, channel]); writeFileSync(at(channel), '{"publicEDKey":"pinned"}\n')
      assert.equal(assertCommitted(directory, files).commit, head, 'restored bytes are accepted again')
    }

    rmSync(at(feed)); symlinkSync(at(channel), at(feed))
    assert.throws(() => assertCommitted(directory, files), Error, 'a symlink is not the committed regular file')
  } finally { rmSync(directory, { recursive: true, force: true }) }
})
