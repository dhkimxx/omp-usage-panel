import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { appendFileSync, lstatSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { appTreeHash as hashAppTree } from './ownership.mjs'
import { archiveName, downloadURL, feedItems, parseItem, verifyFeedText, verifyReleaseAsset } from './release.mjs'
import { channelPath, defaults, feedPath, parseChannel, sourceRoot } from './sparkle.mjs'

// Keyless, read-only audit of what is publicly released. It needs neither the Ed25519 private key nor the Sparkle SDK and never runs the app:
// the committed signed feed is authenticated with the pinned public key, and every item must be backed by a real stable GitHub release
// whose tag points at the signed source commit and whose single DMG verifies (signature before mount, layout, universal deep signature,
// version, tree hash) through the same exported verifier the publisher uses.
const usage = 'Usage: node apps/macos/release-audit.mjs   (audits the committed updates/appcast.xml; takes no options)'
/** What a passing report does and does not establish; printed with every report. */
export const auditScope = 'Audits the COMMITTED signed feed (updates/appcast.xml at the reported commit) against public GitHub releases, tags and assets. ' +
  'It does not read the live raw.githubusercontent.com feed (that CDN can lag after a push), does not hold or check the signing key, and makes no Developer ID/notarization claim.'
const maxTagDepth = 5

/** @typedef {Record<string, any>} Json */
/** @typedef {(path: string) => Json} GitHubApi  Read-only GET of one REST path (without host) returning parsed JSON; throws on any failure. */
/** @typedef {{release: (tag: string) => Json, tagCommit: (tag: string) => string}} GitHub */
/** @typedef {(url: string, file: string, maxBytes: number) => void} Download  Fetches `url` into `file`, never more than `maxBytes` bytes. */
/** @typedef {{version: string, tag: string, item: ReturnType<typeof parseItem> & {sourceCommit: string}}} Entry */
/** @typedef {{version: string, tag: string, ok: true, sourceCommit: string, tagCommit: string, release: {url: string, id: number|null, immutable: boolean|null, publishedAt: string|null}, asset: {name: string, url: string, length: number, sha256: string, githubDigest: 'matched'|'not-reported'}, appTreeSHA256: string}} VerifiedVersion */
/** @typedef {{version: string, tag: string, ok: false, stage: string, error: string}} FailedVersion */

const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/
/** @param {string} a @param {string} b */
function compareVersions(a, b) {
  const left = a.split('.').map(BigInt), right = b.split('.').map(BigInt)
  for (let i = 0; i < 3; i++) { const x = /** @type {bigint} */ (left[i]), y = /** @type {bigint} */ (right[i]); if (x !== y) return x < y ? -1 : 1 }
  return 0
}
/** @param {unknown} error */
const messageOf = error => error instanceof Error ? error.message : String(error)
/** @param {Buffer|string} data */
const sha256 = data => createHash('sha256').update(data).digest('hex')
/** @param {unknown} value @returns {value is Json} */
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)

const sparkleNamespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
/**
 * Runs stock macOS xmllint over the feed text (stdin). Never loads anything from the network; the feed has no DTD (checked before).
 * @param {string[]} args @param {string} text
 */
function xmllint(args, text) {
  return execFileSync('/usr/bin/xmllint', ['--nonet', ...args, '-'], { input: text, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 30000 })
}
/** @param {string} namespace @param {string} name */
const qualified = (namespace, name) => `*[local-name()='${name}' and namespace-uri()='${namespace}']`
/** @param {string} namespace @param {string} name */
const qualifiedAttribute = (namespace, name) => `@*[local-name()='${name}' and namespace-uri()='${namespace}']`

/**
 * The items an RSS consumer really sees, read through a namespace-aware XML parser: the feed must be well-formed RSS 2.0 with every item
 * a direct, unprefixed child of the single channel and each field present exactly once in its correct namespace. Text that merely looks
 * like an item (in a comment, CDATA or another namespace) or fields whose prefix is bound elsewhere are rejected.
 * @param {string} feedText
 */
function xmlItems(feedText) {
  if (/<!DOCTYPE|<!ENTITY/i.test(feedText)) throw new Error('The signed feed declares a DTD or entities, which an update feed must not')
  try { xmllint(['--noout'], feedText) } catch (error) { throw new Error(`The signed feed is not well-formed XML: ${messageOf(error).split('\n').slice(0, 3).join(' ')}`) }
  // xmllint terminates every printed result with one newline that is not part of the value.
  /** @param {string} expression */
  const evaluate = expression => { const output = xmllint(['--xpath', expression], feedText); return output.endsWith('\n') ? output.slice(0, -1) : output }
  /** @param {string} expression */
  const count = expression => Number(evaluate(`count(${expression})`))
  if (count('/*') !== 1 || count('/rss') !== 1 || evaluate('string(/rss/@version)') !== '2.0' || count('/rss/channel') !== 1) throw new Error('The signed feed is not an RSS 2.0 document with a single channel')
  const total = count('/rss/channel/item')
  if (count("//*[local-name()='item']") !== total) throw new Error('The signed feed has item elements outside the channel or in another namespace')
  return Array.from({ length: total }, (_, index) => {
    const base = `/rss/channel/item[${index + 1}]`
    /** @param {string} child @param {string} label */
    const single = (child, label) => {
      if (count(`${base}/${child}`) !== 1) throw new Error(`Feed item ${index + 1} must carry exactly one ${label}`)
      return child
    }
    /** @param {string} child @param {string} label */
    const text = (child, label) => evaluate(`string(${base}/${single(child, label)})`)
    const enclosure = single('enclosure', 'enclosure'), description = single('description', 'description')
    /** @param {string} parent @param {string} attribute @param {string} label */
    const attributeOf = (parent, attribute, label) => {
      if (count(`${base}/${parent}/${attribute}`) !== 1) throw new Error(`Feed item ${index + 1} ${parent} must carry exactly one ${label}`)
      return evaluate(`string(${base}/${parent}/${attribute})`)
    }
    return {
      version: text(qualified(sparkleNamespace, 'version'), 'sparkle:version'),
      shortVersion: text(qualified(sparkleNamespace, 'shortVersionString'), 'sparkle:shortVersionString'),
      appTreeSHA256: text(qualified(defaults.namespace, 'appTreeSHA256'), 'omp:appTreeSHA256'),
      sourceCommit: count(`${base}/${qualified(defaults.namespace, 'sourceCommit')}`) === 0 ? '' : text(qualified(defaults.namespace, 'sourceCommit'), 'omp:sourceCommit'),
      notes: evaluate(`string(${base}/${description})`),
      notesFormat: attributeOf(description, qualifiedAttribute(sparkleNamespace, 'descriptionFormat'), 'sparkle:descriptionFormat'),
      url: attributeOf(enclosure, '@url', 'url'),
      length: attributeOf(enclosure, '@length', 'length'),
      type: attributeOf(enclosure, '@type', 'type'),
      signature: attributeOf(enclosure, qualifiedAttribute(sparkleNamespace, 'edSignature'), 'sparkle:edSignature'),
    }
  })
}

/**
 * Authenticates the feed bytes and turns each item into a strictly validated entry. Everything here is offline: a feed that fails
 * is rejected before any network access. Items are read as an XML consumer sees them, then the existing release parser must agree
 * with that reading field by field.
 * @param {string} feedText @param {string} publicEDKey @param {string} label
 * @returns {Entry[]}
 */
export function feedEntries(feedText, publicEDKey, label = 'committed feed') {
  verifyFeedText(feedText, publicEDKey, label)
  const real = xmlItems(feedText), items = feedItems(feedText)
  if (!real.length) throw new Error('The signed feed lists no release; there is nothing to audit')
  if (items.length !== real.length || (feedText.match(/<item[\s>]/g) ?? []).length !== real.length) throw new Error('The signed feed has item-like markup that is not a real RSS item (a comment, CDATA or malformed element)')
  /** @type {Entry[]} */
  const entries = []
  for (const [index, xml] of real.entries()) {
    const version = xml.version
    if (!semver.test(version)) throw new Error(`Feed version ${JSON.stringify(version)} is not a strict MAJOR.MINOR.PATCH version`)
    if (xml.shortVersion !== version) throw new Error(`Feed item ${version} has a different short version string`)
    const parsed = (() => { try { return parseItem(/** @type {string} */ (items[index])) } catch (error) { throw new Error(`Feed item ${version}: ${messageOf(error)}`) } })()
    // An XML parser normalizes CRLF and CR in the notes to LF; the text parser sees the raw bytes.
    if (xml.url !== parsed.url || xml.length !== String(parsed.length) || xml.signature !== parsed.signature || xml.appTreeSHA256 !== parsed.appTreeSHA256 || xml.sourceCommit !== (parsed.sourceCommit ?? '') ||
        xml.notes !== parsed.notes.replace(/\r\n?/g, '\n') || xml.type !== 'application/octet-stream' || xml.notesFormat !== 'plain-text') throw new Error(`Feed item ${version} reads differently as XML than as text; refusing an ambiguous feed`)
    if (parsed.url !== downloadURL(version)) throw new Error(`Feed item ${version} does not point at the canonical release asset ${downloadURL(version)}`)
    if (!parsed.sourceCommit) throw new Error(`Feed item ${version} carries no signed source commit, so its tag cannot be bound to a source`)
    const previous = entries.at(-1)
    if (entries.some(entry => entry.version === version)) throw new Error(`Feed lists version ${version} more than once`)
    if (previous && compareVersions(previous.version, version) > 0) throw new Error(`Feed versions must ascend: ${version} follows ${previous.version}`)
    entries.push({ version, tag: `v${version}`, item: { ...parsed, sourceCommit: parsed.sourceCommit } })
  }
  return entries
}

/**
 * GitHub release and tag facts through a read-only REST client. The tag commit is the object the tag really peels to; neither the release's
 * target_commitish nor any later feed commit is consulted.
 * @param {{repository?: string, api: GitHubApi}} options @returns {GitHub}
 */
export function githubClient({ repository = defaults.repository, api }) {
  return {
    release: tag => api(`repos/${repository}/releases/tags/${tag}`),
    tagCommit(tag) {
      const ref = api(`repos/${repository}/git/ref/tags/${tag}`)
      if (ref.ref !== `refs/tags/${tag}`) throw new Error(`GitHub returned ${JSON.stringify(ref.ref)} for tag ${tag}`)
      let object = ref.object
      for (let depth = 0; depth < maxTagDepth; depth++) {
        if (!isObject(object) || typeof object.sha !== 'string' || !/^[a-f0-9]{40}$/.test(object.sha)) throw new Error(`Tag ${tag} resolves to an invalid object`)
        if (object.type === 'commit') return object.sha
        if (object.type !== 'tag') throw new Error(`Tag ${tag} points at a ${object.type}, not a commit`)
        object = api(`repos/${repository}/git/tags/${object.sha}`).object
      }
      throw new Error(`Tag ${tag} is nested more than ${maxTagDepth} annotated tags deep`)
    },
  }
}

/** @type {GitHubApi} */
const ghApi = apiPath => JSON.parse(execFileSync('gh', ['api', '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28', apiPath], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000 }))
/** @type {Download} */
const curlDownload = (url, file, maxBytes) => { execFileSync('/usr/bin/curl', ['--fail', '--location', '--proto', '=https', '--proto-redir', '=https', '--silent', '--show-error', '--retry', '3', '--connect-timeout', '20', '--max-time', '300', '--max-filesize', String(maxBytes), '--output', file, url], { stdio: 'inherit' }) }

/**
 * The release must be a published, stable release carrying exactly the signed item's DMG.
 * @param {Json} release @param {Entry} entry
 * @returns {{asset: Json, digest: string|undefined}}
 */
function assertRelease(release, { tag, item, version }) {
  if (!isObject(release) || release.tag_name !== tag) throw new Error(`GitHub release is not the release for tag ${tag}`)
  if (release.draft !== false) throw new Error(`Release ${tag} is a draft`)
  if (release.prerelease !== false) throw new Error(`Release ${tag} is a prerelease`)
  const assets = Array.isArray(release.assets) ? release.assets : []
  const names = assets.map(asset => isObject(asset) ? asset.name : undefined)
  if (assets.length !== 1 || names[0] !== archiveName(version)) throw new Error(`Release ${tag} must carry exactly ${archiveName(version)}; it has [${names.join(', ')}]`)
  const asset = assets[0]
  if (asset.state !== 'uploaded') throw new Error(`Release asset ${asset.name} is not fully uploaded (${asset.state})`)
  if (asset.browser_download_url !== item.url) throw new Error(`Release asset URL ${asset.browser_download_url} differs from the signed feed enclosure`)
  if (asset.size !== item.length) throw new Error(`Release asset size ${asset.size} differs from the signed feed length ${item.length}`)
  let digest
  if (asset.digest !== null && asset.digest !== undefined) {
    const match = typeof asset.digest === 'string' ? /^sha256:([a-f0-9]{64})$/.exec(asset.digest) : null
    if (!match) throw new Error(`Release asset digest ${JSON.stringify(asset.digest)} is not a sha256 digest`)
    digest = match[1]
  }
  return { asset, digest }
}

/**
 * Audits every item of an already authenticated feed. A failing version never hides the others; `ok` is true only when all verify.
 * @param {{feedText: string, publicEDKey: string, github: GitHub, download: Download, appTreeHash?: (app: string) => string, label?: string}} options
 * @returns {{ok: boolean, feedSHA256: string, versions: (VerifiedVersion|FailedVersion)[]}}
 */
export function auditFeed({ feedText, publicEDKey, github, download, appTreeHash = hashAppTree, label }) {
  const entries = feedEntries(feedText, publicEDKey, label)
  /** @type {(VerifiedVersion|FailedVersion)[]} */
  const versions = []
  for (const entry of entries) {
    const { version, tag, item } = entry, directory = mkdtempSync(path.join(tmpdir(), 'omp-release-audit-'))
    let stage = 'release'
    try {
      const release = github.release(tag), { asset, digest } = assertRelease(release, entry)
      stage = 'tag'
      const tagCommit = github.tagCommit(tag)
      if (tagCommit !== item.sourceCommit) throw new Error(`Tag ${tag} points at ${tagCommit}, but the signed feed was built from ${item.sourceCommit}`)
      stage = 'download'
      const file = path.join(directory, archiveName(version))
      download(item.url, file, item.length)
      if (statSync(file).size !== item.length) throw new Error(`Downloaded asset is ${statSync(file).size} bytes, the signed feed says ${item.length}`)
      const archiveSHA256 = sha256(readFileSync(file))
      if (digest !== undefined && digest !== archiveSHA256) throw new Error(`GitHub reports asset digest ${digest}, but the downloaded bytes hash to ${archiveSHA256}`)
      stage = 'asset'
      verifyReleaseAsset({ file, item, version, publicEDKey, appTreeHash })
      versions.push({
        version, tag, ok: true, sourceCommit: item.sourceCommit, tagCommit,
        release: { url: String(release.html_url ?? ''), id: typeof release.id === 'number' ? release.id : null, immutable: typeof release.immutable === 'boolean' ? release.immutable : null, publishedAt: typeof release.published_at === 'string' ? release.published_at : null },
        asset: { name: asset.name, url: item.url, length: item.length, sha256: archiveSHA256, githubDigest: digest === undefined ? 'not-reported' : 'matched' },
        appTreeSHA256: item.appTreeSHA256,
      })
    } catch (error) { versions.push({ version, tag, ok: false, stage, error: messageOf(error) }) }
    finally { rmSync(directory, { recursive: true, force: true }) }
  }
  return { ok: versions.every(entry => entry.ok), feedSHA256: sha256(feedText), versions }
}

/**
 * Proves that each file is a regular file committed at HEAD and that the working copy is byte-identical to that blob, and returns the blob bytes.
 * The comparison is against the blob itself, never `git status`, so assume-unchanged / skip-worktree flags cannot hide a modified feed or pinned key.
 * Blobs are read with `cat-file` (no textconv or filters).
 * @param {string} root @param {string[]} relativePaths
 * @returns {{commit: string, files: Record<string, Buffer>}}
 */
export function assertCommitted(root, relativePaths) {
  /** @param {string[]} args @returns {Buffer} */
  const git = (...args) => execFileSync('/usr/bin/git', ['-C', root, ...args], { stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024 })
  const commit = git('rev-parse', 'HEAD').toString('utf8').trim()
  /** @type {Record<string, Buffer>} */
  const files = {}
  for (const file of relativePaths) {
    /** @type {Buffer} */
    let blob
    try {
      if (!/^100(644|755) blob /.test(git('ls-tree', commit, '--', file).toString('utf8'))) throw new Error('not a regular blob')
      blob = git('cat-file', 'blob', `${commit}:${file}`)
    } catch { throw new Error(`${file} is not a regular file committed at ${commit}; the audit only covers committed files`) }
    const working = lstatSync(path.join(root, file), { throwIfNoEntry: false })
    if (!working?.isFile() || !readFileSync(path.join(root, file)).equals(blob)) throw new Error(`${file} differs from its committed blob at ${commit}; commit or restore it first`)
    files[file] = blob
  }
  return { commit, files }
}

/** @param {{ok: boolean, versions: (VerifiedVersion|FailedVersion)[]}} report @param {string} commit */
function stepSummary(report, commit) {
  const rows = report.versions.map(entry => entry.ok
    ? `| ${entry.version} | verified | ${entry.tagCommit.slice(0, 12)} | ${entry.asset.sha256.slice(0, 16)} |`
    : `| ${entry.version} | **FAILED** (${entry.stage}) | | ${entry.error.replace(/\|/g, '\\|').replace(/\s+/g, ' ')} |`)
  return `## OMP Usage public release audit: ${report.ok ? 'passed' : 'FAILED'}\n\nCommitted feed at \`${commit}\`; GitHub releases, tags and assets.\n\n| Version | Result | Tag commit | Asset SHA-256 / error |\n| --- | --- | --- | --- |\n${rows.join('\n')}\n`
}

function main() {
  if (process.argv.length > 2) throw new Error(usage)
  const feedRelative = path.relative(sourceRoot, feedPath), channelRelative = path.relative(sourceRoot, channelPath)
  // Both the feed and the pinned key come from the committed blobs themselves (proven identical to the working copies), never from a second read of a mutable file.
  const { commit, files } = assertCommitted(sourceRoot, [feedRelative, channelRelative])
  const channel = parseChannel(/** @type {Buffer} */ (files[channelRelative]))
  const result = auditFeed({ feedText: /** @type {Buffer} */ (files[feedRelative]).toString('utf8'), publicEDKey: channel.publicEDKey, github: githubClient({ api: ghApi }), download: curlDownload, label: feedRelative })
  const report = { audit: 'omp-usage-public-release-audit', scope: auditScope, repository: defaults.repository, feed: { path: feedRelative, commit, sha256: result.feedSHA256 }, publicEDKey: channel.publicEDKey, ok: result.ok, versions: result.versions }
  console.log(JSON.stringify(report, null, 2))
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, stepSummary(report, commit))
  if (!report.ok) process.exitCode = 1
}
if (import.meta.main) main()
