import test, { after } from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { createDmg } from './dmg.mjs'
import { appTreeHash } from './ownership.mjs'
import { archiveName } from './release.mjs'
import { artifactName, attestsRun, buildCandidate, candidateManifestName, parseCandidate, renderCandidate, trustedRun, trustedTrigger, verifyCandidateRun, withVerifiedCandidate, workflowPath } from './ci-release.mjs'
import { defaults, rootVersion } from './sparkle.mjs'
import { buildFixtureApp, fixtureNodePin, inTemp, recordingHdiutil } from './release-fixtures.mjs'

// Boundaries exercised for real: the DMG (hdiutil, universal ad-hoc-signed fixture app) and the candidate files. GitHub itself cannot run in a
// test, so `createGitHub` stands in for the `gh` executable: it serves the REST shapes the code reads and enforces the `gh attestation verify`
// policy flags against certificates carrying the real GitHub Actions OIDC extension fields (shapes captured from a live `gh attestation verify
// --format json`). Anything else the code asks `gh` for fails the test, which keeps verification read-only.
const darwin = { skip: process.platform !== 'darwin' }
const repository = defaults.repository, version = rootVersion(), head = 'c'.repeat(40)
/** @param {string | Buffer} data */
const sha256 = data => createHash('sha256').update(data).digest('hex')
/** @param {string} value */
const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** @typedef {{runId: number, attempt: number, head: string, ref: string, event: 'workflow_dispatch' | 'push'}} Identity */
/** The certificate GitHub issues to a workflow job; none of these fields can be chosen by workflow code. @param {Identity} identity @param {Record<string, string>} [overrides] */
function certificateFor({ runId, attempt, head: commit, ref, event }, overrides = {}) {
  const base = `https://github.com/${repository}`, workflowURI = `${base}/${workflowPath}@${ref}`
  return {
    certificateIssuer: 'CN=sigstore-intermediate,O=sigstore.dev', subjectAlternativeName: workflowURI, issuer: 'https://token.actions.githubusercontent.com',
    githubWorkflowTrigger: event, githubWorkflowSHA: commit, githubWorkflowName: 'Package', githubWorkflowRepository: repository, githubWorkflowRef: ref,
    buildSignerURI: workflowURI, buildSignerDigest: commit, runnerEnvironment: 'github-hosted', sourceRepositoryURI: base, sourceRepositoryDigest: commit,
    sourceRepositoryRef: ref, sourceRepositoryOwnerURI: 'https://github.com/dhkimxx', buildConfigURI: workflowURI, buildConfigDigest: commit, buildTrigger: event,
    runInvocationURI: `${base}/actions/runs/${runId}/attempts/${attempt}`, sourceRepositoryVisibilityAtSigning: 'public', ...overrides,
  }
}
/** @param {string} stderr */
const ghError = stderr => Object.assign(new Error('gh failed'), { stderr })

/**
 * @param {{identity?: Partial<Identity>, run?: Record<string, unknown>}} [options]  `identity` is what the artifact and attestations were produced for; `run` overrides what the API reports.
 */
function createGitHub({ identity: given = {}, run: runOverrides = {} } = {}) {
  /** @type {Identity} */
  const identity = { runId: 9001, attempt: 1, head, ref: 'refs/heads/main', event: 'workflow_dispatch', ...given }
  const branch = identity.ref.replace(/^refs\/(heads|tags)\//, '')
  const state = {
    identity, sourceVersion: version,
    run: /** @type {Record<string, any>} */ ({
      id: identity.runId, name: 'Package', head_branch: branch, head_sha: identity.head, path: identity.event === 'push' ? `${workflowPath}@${identity.ref}` : workflowPath, event: identity.event,
      status: 'completed', conclusion: 'success', run_attempt: identity.attempt, repository: { full_name: repository }, head_repository: { full_name: repository, fork: false }, ...runOverrides,
    }),
    /** @type {any[]} */ artifacts: [],
    /** @type {Map<string, Map<string, Buffer>>} */ files: new Map(),
    /** @type {{digest: string, certificate: ReturnType<typeof certificateFor>}[]} */ attestations: [],
    /** @type {string[][]} */ calls: [],
    /** @type {(() => void) | undefined} */ afterDownload: undefined,
  }
  /** @param {Buffer} bytes @param {Record<string, string>} [overrides] @param {Partial<Identity>} [other] */
  const attest = (bytes, overrides, other) => { state.attestations.push({ digest: sha256(bytes), certificate: certificateFor({ ...identity, ...other }, overrides) }) }
  /** Applies the policy `gh attestation verify` enforces for the flags it is given. @param {ReturnType<typeof certificateFor>} certificate @param {Map<string, string | true>} flags */
  const policyAllows = (certificate, flags) => {
    const repo = flags.get('--repo'), workflow = flags.get('--signer-workflow')
    if (typeof repo !== 'string' || certificate.sourceRepositoryURI !== `https://github.com/${repo}`) return false
    if (typeof workflow !== 'string' || !new RegExp(`^https://github\\.com/${escapeRegExp(workflow)}(@refs/.*)?$`).test(certificate.subjectAlternativeName)) return false
    if (flags.has('--source-digest') && flags.get('--source-digest') !== certificate.sourceRepositoryDigest) return false
    if (flags.has('--signer-digest') && flags.get('--signer-digest') !== certificate.buildSignerDigest) return false
    if (flags.has('--source-ref') && flags.get('--source-ref') !== certificate.sourceRepositoryRef) return false
    if (flags.has('--deny-self-hosted-runners') && certificate.runnerEnvironment !== 'github-hosted') return false
    return certificate.issuer === 'https://token.actions.githubusercontent.com'
  }
  /** @param {string[]} args */
  const gh = args => {
    state.calls.push(args)
    if (args[0] === 'api') {
      const target = args.at(-1) ?? '', prefix = `repos/${repository}/`
      if (target === `${prefix}actions/runs/${state.run.id}`) return JSON.stringify(state.run)
      if (target.startsWith(`${prefix}actions/runs/${state.run.id}/artifacts?`)) {
        const name = new URLSearchParams(target.split('?')[1]).get('name')
        const artifacts = state.artifacts.filter(artifact => artifact.name === name)
        return JSON.stringify({ total_count: artifacts.length, artifacts })
      }
      if (target === `${prefix}contents/package.json?ref=${state.run.head_sha}`) return JSON.stringify({ name: 'omp-usage-panel', version: state.sourceVersion })
      throw ghError(`HTTP 404: Not Found (${target})`)
    }
    if (args[0] === 'run' && args[1] === 'download') {
      const flags = new Map(); for (let i = 3; i < args.length; i += 2) flags.set(args[i], args[i + 1])
      const files = state.files.get(flags.get('--name') ?? '')
      if (args[2] !== String(state.run.id) || flags.get('--repo') !== repository || !files) throw ghError('no artifact matches any of the names or patterns provided')
      for (const [name, bytes] of files) writeFileSync(path.join(/** @type {string} */ (flags.get('--dir')), name), bytes)
      state.afterDownload?.()
      return ''
    }
    if (args[0] === 'attestation' && args[1] === 'verify') {
      const file = args[2] ?? '', flags = /** @type {Map<string, string | true>} */ (new Map())
      for (let i = 3; i < args.length; i++) { const flag = args[i] ?? ''; if (flag === '--deny-self-hosted-runners') flags.set(flag, true); else flags.set(flag, args[++i] ?? '') }
      const digest = sha256(readFileSync(file))
      const matching = state.attestations.filter(entry => entry.digest === digest && policyAllows(entry.certificate, flags))
      if (!matching.length) throw ghError('Error: verifying with issuer "sigstore.dev": no attestation matched the policy')
      return JSON.stringify(matching.map(entry => ({
        attestation: {},
        verificationResult: { mediaType: 'application/vnd.dev.sigstore.verificationresult+json;version=0.1', signature: { certificate: entry.certificate }, verifiedTimestamps: [], statement: { _type: 'https://in-toto.io/Statement/v1', subject: [{ name: 'artifact', digest: { sha256: digest } }], predicateType: 'https://slsa.dev/provenance/v1', predicate: {} } },
      })))
    }
    throw new Error(`unexpected gh call: ${args.join(' ')}`)
  }
  return { state, gh, attest }
}

/** @type {{directory: string, bytes: Buffer, tree: string} | undefined} */
let shared
/** One real, correct candidate image, built once. */
function goodImage() {
  if (!shared) {
    const directory = mkdtempSync(path.join(tmpdir(), 'omp-ci-release-fixture-')), app = buildFixtureApp(directory, { version })
    shared = { directory, bytes: readFileSync(createDmg({ app, output: path.join(directory, archiveName(version)) })), tree: appTreeHash(app) }
  }
  return shared
}
after(() => { if (shared) rmSync(shared.directory, { recursive: true, force: true }) })
/** A real image of a different fixture app. @param {string} directory @param {{version?: string, universal?: boolean}} options */
function otherImage(directory, options) {
  const app = buildFixtureApp(directory, options)
  return { bytes: readFileSync(createDmg({ app, output: path.join(directory, `${path.basename(path.dirname(app))}.dmg`) })), tree: appTreeHash(app) }
}

/**
 * What the Package workflow leaves behind for one run: the artifact (DMG + candidate.json) and attestations of both files.
 * @param {ReturnType<typeof createGitHub>} github @param {{bytes: Buffer, tree: string}} image
 * @param {{manifest?: Record<string, unknown>, attestDmg?: boolean, attestManifest?: boolean, artifact?: Record<string, unknown>, extraFiles?: [string, Buffer][], omit?: string[]}} [options]
 */
function publishCandidate(github, image, { manifest = {}, attestDmg = true, attestManifest = true, artifact = {}, extraFiles = [], omit = [] } = {}) {
  const { identity, run } = github.state
  const claimed = /** @type {any} */ ({
    schema: 1, repository, workflow: workflowPath, event: identity.event, ref: identity.ref, sourceCommit: identity.head, runId: String(identity.runId), runAttempt: identity.attempt,
    version, archiveName: archiveName(version), length: image.bytes.length, archiveSHA256: sha256(image.bytes), appTreeSHA256: image.tree, ...manifest,
  })
  const manifestBytes = Buffer.from(`${JSON.stringify(claimed, null, 2)}\n`)
  const name = artifactName({ sourceCommit: identity.head, runId: identity.runId, runAttempt: identity.attempt })
  github.state.artifacts.push({ id: 1, name, size_in_bytes: image.bytes.length, expired: false, workflow_run: { id: identity.runId, head_branch: run.head_branch, head_sha: identity.head }, ...artifact })
  const files = new Map([[archiveName(version), image.bytes], [candidateManifestName, manifestBytes], ...extraFiles])
  for (const file of omit) files.delete(file)
  github.state.files.set(name, files)
  if (attestDmg) github.attest(image.bytes)
  if (attestManifest) github.attest(manifestBytes)
  return { name, manifestBytes }
}
/**
 * Runs the read-only verification and asserts it refused, with no temporary download left behind. The real hdiutil records every attach: a
 * refusal at a provenance or artifact check must never have attached the image, while a refusal found by inspecting the image attached it once.
 * Each refusal case differs from the verified baseline in exactly one aspect, so the refusal is that aspect's doing, not any error text.
 * @param {ReturnType<typeof createGitHub>} github @param {string} label @param {string} directory @param {{attaches?: boolean}} [options]
 */
function assertRefused(github, label, directory, { attaches = false } = {}) {
  const temporaryRoot = mkdtempSync(path.join(directory, 'tmp-')), { attached, hdiutil } = recordingHdiutil()
  assert.throws(() => verifyCandidateRun({ runId: String(github.state.run.id), appTreeHash, gh: github.gh, temporaryRoot, hdiutil }), label)
  assert.equal(attached.length, attaches ? 1 : 0, `${label}: ${attaches ? 'the image was inspected through one read-only mount' : 'the image was never attached'}`)
  assert.deepEqual(readdirSync(temporaryRoot), [], `${label}: the downloaded files were removed`)
}

const goodRun = {
  id: 9001, head_branch: 'main', head_sha: head, path: workflowPath, event: 'workflow_dispatch', status: 'completed', conclusion: 'success', run_attempt: 3,
  repository: { full_name: repository }, head_repository: { full_name: repository, fork: false },
}
test('only completed successful Package runs of this repository on main or a version tag are trusted', () => {
  assert.deepEqual(trustedRun(goodRun, { runId: '9001', head }), { id: 9001, attempt: 3, head, event: 'workflow_dispatch', branch: 'main', ref: 'refs/heads/main', tagVersion: undefined })
  const tag = trustedRun({ ...goodRun, event: 'push', head_branch: 'v1.2.3', path: `${workflowPath}@refs/tags/v1.2.3` }, { runId: '9001' })
  assert.equal(tag.ref, 'refs/tags/v1.2.3'); assert.equal(tag.tagVersion, '1.2.3')
  /** @type {[string, Record<string, unknown>][]} */
  const refusals = [
    ['a run from a fork', { head_repository: { full_name: 'attacker/omp-usage-panel', fork: true } }],
    ['a run flagged as a fork', { head_repository: { full_name: repository, fork: true } }],
    ['another repository', { repository: { full_name: 'other/omp-usage-panel' } }],
    ['another workflow', { path: '.github/workflows/verify.yml' }],
    ['the workflow file of another branch', { path: `${workflowPath}@refs/heads/feature` }],
    ['a run still in progress', { status: 'in_progress', conclusion: null }],
    ['a failed run', { conclusion: 'failure' }],
    ['a cancelled run', { conclusion: 'cancelled' }],
    ['a pull request run', { event: 'pull_request' }],
    ['a scheduled run', { event: 'schedule' }],
    ['a manual run on another branch', { head_branch: 'feature/x' }],
    ['a push to a branch', { event: 'push', head_branch: 'main' }],
    ['a tag that is not a full version', { event: 'push', head_branch: 'v1.0' }],
    ['another commit than the checkout', { head_sha: 'd'.repeat(40) }],
    ['a malformed commit', { head_sha: 'abc' }],
    ['a run without an attempt number', { run_attempt: undefined }],
    ['a different run than asked for', { id: 5 }],
  ]
  for (const [label, change] of refusals) assert.throws(() => trustedRun({ ...goodRun, ...change }, { runId: '9001', head }), label)
})

test('an attestation counts only when it binds the digest to this exact run, attempt, commit, ref, workflow and hosted runner', () => {
  const identity = /** @type {Identity} */ ({ runId: 9001, attempt: 1, head, ref: 'refs/heads/main', event: 'workflow_dispatch' })
  const run = { id: 9001, attempt: 1, head, event: /** @type {'workflow_dispatch'} */ ('workflow_dispatch'), branch: 'main', ref: 'refs/heads/main', tagVersion: undefined }
  const digest = sha256('dmg')
  /** @param {Record<string, string>} [overrides] @param {string} [subject] */
  const results = (overrides, subject = digest) => [{ verificationResult: { signature: { certificate: certificateFor(identity, overrides) }, statement: { subject: [{ name: 'x', digest: { sha256: subject } }] } } }]
  assert.equal(attestsRun(results(), { sha256: digest, run, repository }), true)
  /** @type {[string, unknown][]} */
  const refusals = [
    ['another digest', results({}, sha256('other'))],
    ['the previous attempt of the run', results({ runInvocationURI: `https://github.com/${repository}/actions/runs/9001/attempts/2` })],
    ['another run', results({ runInvocationURI: `https://github.com/${repository}/actions/runs/9002/attempts/1` })],
    ['another source commit', results({ sourceRepositoryDigest: 'd'.repeat(40) })],
    ['another signer commit', results({ buildSignerDigest: 'd'.repeat(40) })],
    ['another ref', results({ sourceRepositoryRef: 'refs/heads/feature' })],
    ['another trigger', results({ githubWorkflowTrigger: 'push' })],
    ['a self-hosted runner', results({ runnerEnvironment: 'self-hosted' })],
    ['another workflow', results({ subjectAlternativeName: `https://github.com/${repository}/.github/workflows/verify.yml@refs/heads/main` })],
    ['another repository', results({ sourceRepositoryURI: 'https://github.com/other/omp-usage-panel' })],
    ['another issuer', results({ issuer: 'https://accounts.example.com' })],
    ['no results', []],
    ['unreadable results', { not: 'an array' }],
  ]
  for (const [label, candidates] of refusals) assert.equal(attestsRun(candidates, { sha256: digest, run, repository }), false, label)
})

test('candidates are built only for a manual run on main or the matching version tag, in this repository, on a GitHub-hosted runner', () => {
  /** @type {NodeJS.ProcessEnv} */
  const trusted = {
    GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository, GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/main', GITHUB_SHA: head,
    GITHUB_WORKFLOW_REF: `${repository}/${workflowPath}@refs/heads/main`, RUNNER_ENVIRONMENT: 'github-hosted', GITHUB_RUN_ID: '9001', GITHUB_RUN_ATTEMPT: '2',
  }
  assert.deepEqual(trustedTrigger(trusted, '1.2.3'), { repository, event: 'workflow_dispatch', ref: 'refs/heads/main', sourceCommit: head, runId: '9001', runAttempt: 2 })
  const tag = trustedTrigger({ ...trusted, GITHUB_EVENT_NAME: 'push', GITHUB_REF: 'refs/tags/v1.2.3', GITHUB_WORKFLOW_REF: `${repository}/${workflowPath}@refs/tags/v1.2.3` }, '1.2.3')
  assert.equal(tag.ref, 'refs/tags/v1.2.3')
  /** @type {[string, NodeJS.ProcessEnv][]} */
  const refusals = [
    ['a local shell', { ...trusted, GITHUB_ACTIONS: undefined }],
    ['a fork', { ...trusted, GITHUB_REPOSITORY: 'attacker/omp-usage-panel' }],
    ['a self-hosted runner', { ...trusted, RUNNER_ENVIRONMENT: 'self-hosted' }],
    ['another workflow', { ...trusted, GITHUB_WORKFLOW_REF: `${repository}/.github/workflows/verify.yml@refs/heads/main` }],
    ['a pull request', { ...trusted, GITHUB_EVENT_NAME: 'pull_request' }],
    ['a manual run on another branch', { ...trusted, GITHUB_REF: 'refs/heads/feature', GITHUB_WORKFLOW_REF: `${repository}/${workflowPath}@refs/heads/feature` }],
    ['a tag of another version', { ...trusted, GITHUB_EVENT_NAME: 'push', GITHUB_REF: 'refs/tags/v9.9.9', GITHUB_WORKFLOW_REF: `${repository}/${workflowPath}@refs/tags/v9.9.9` }],
    ['a push to a branch', { ...trusted, GITHUB_EVENT_NAME: 'push' }],
    ['an abbreviated commit', { ...trusted, GITHUB_SHA: 'abc123' }],
    ['a bad run attempt', { ...trusted, GITHUB_RUN_ATTEMPT: '0' }],
  ]
  for (const [label, env] of refusals) assert.throws(() => trustedTrigger(env, '1.2.3'), label)
})

test('the candidate manifest is parsed strictly and round-trips', () => {
  const manifest = parseCandidate(renderCandidate({ schema: 1, repository, workflow: workflowPath, event: 'push', ref: 'refs/tags/v1.0.1', sourceCommit: head, runId: '9001', runAttempt: 1, version: '1.0.1', archiveName: 'OMP-Usage-1.0.1.dmg', length: 5, archiveSHA256: sha256('a'), appTreeSHA256: sha256('b') }))
  assert.equal(manifest.ref, 'refs/tags/v1.0.1'); assert.equal(manifest.length, 5)
  const text = renderCandidate(manifest), object = JSON.parse(text)
  assert.deepEqual(parseCandidate(text), manifest, 'a rendered manifest parses back unchanged')
  for (const [label, changed] of /** @type {[string, unknown][]} */ ([
    ['an unknown field', { ...object, extra: 1 }], ['a missing field', { ...object, length: undefined }], ['a wrong schema', { ...object, schema: 2 }],
    ['a path-like archive name', { ...object, archiveName: '../OMP-Usage-1.0.1.dmg' }], ['a short commit', { ...object, sourceCommit: 'abc' }], ['a non-numeric run id', { ...object, runId: 'x' }],
    ['a string length', { ...object, length: '5' }], ['an array', []], ['null', null],
  ])) assert.throws(() => parseCandidate(JSON.stringify(changed)), label)
  assert.throws(() => parseCandidate('{'))
})

test('a run is verified read-only: provenance, layout, universal app, version and tree, leaving no download behind', darwin, () => inTemp(directory => {
  const github = createGitHub(), image = goodImage()
  publishCandidate(github, image)
  const temporaryRoot = mkdtempSync(path.join(directory, 'tmp-'))
  const result = verifyCandidateRun({ runId: '9001', appTreeHash, gh: github.gh, temporaryRoot })
  assert.deepEqual({ ...result, note: undefined }, {
    verified: true, run: 9001, attempt: 1, event: 'workflow_dispatch', ref: 'refs/heads/main', sourceCommit: head, version,
    artifact: artifactName({ sourceCommit: head, runId: 9001, runAttempt: 1 }), archiveName: archiveName(version), length: image.bytes.length, archiveSHA256: sha256(image.bytes), appTreeSHA256: image.tree, note: undefined,
  })
  assert.deepEqual(readdirSync(temporaryRoot), [], 'the downloaded candidate was removed')
}))

test('a version-tag run is verified against the tag ref and the version it declares', darwin, () => inTemp(directory => {
  const ref = `refs/tags/v${version}`, image = goodImage()
  const github = createGitHub({ identity: { ref, event: 'push' } })
  publishCandidate(github, image)
  const result = verifyCandidateRun({ runId: '9001', appTreeHash, gh: github.gh, temporaryRoot: directory })
  assert.equal(result.event, 'push'); assert.equal(result.ref, ref)
  const mismatched = createGitHub({ identity: { ref: 'refs/tags/v9.9.9', event: 'push' } })
  publishCandidate(mismatched, image)
  assertRefused(mismatched, 'a tag of another version than package.json', directory)
}))

test('artifacts that are stale, ambiguous, expired, foreign or malformed are refused before provenance is even asked', darwin, () => inTemp(directory => {
  const image = goodImage()
  const staleAttempt = createGitHub({ run: { run_attempt: 2 } }); publishCandidate(staleAttempt, image)
  assertRefused(staleAttempt, 'the artifact of an earlier attempt', directory)
  const ambiguous = createGitHub(); publishCandidate(ambiguous, image); ambiguous.state.artifacts.push({ ...ambiguous.state.artifacts[0], id: 2 })
  assertRefused(ambiguous, 'two artifacts of the same name', directory)
  const expired = createGitHub(); publishCandidate(expired, image, { artifact: { expired: true } })
  assertRefused(expired, 'an expired artifact', directory)
  const foreign = createGitHub(); publishCandidate(foreign, image, { artifact: { workflow_run: { id: 1234, head_branch: 'main', head_sha: head } } })
  assertRefused(foreign, 'an artifact of another run', directory)
  const otherCommit = createGitHub(); publishCandidate(otherCommit, image, { artifact: { workflow_run: { id: 9001, head_branch: 'main', head_sha: 'd'.repeat(40) } } })
  assertRefused(otherCommit, 'an artifact of another commit', directory)
  const failed = createGitHub({ run: { conclusion: 'failure' } }); publishCandidate(failed, image)
  assertRefused(failed, 'a failed run', directory)
  assertRefused(createGitHub(), 'a run without any artifact', directory)
  const extra = createGitHub(); publishCandidate(extra, image, { extraFiles: [['run.sh', Buffer.from('#!/bin/sh\n')]] })
  assertRefused(extra, 'an extra file', directory)
  const noManifest = createGitHub(); publishCandidate(noManifest, image, { omit: [candidateManifestName] })
  assertRefused(noManifest, 'a missing manifest', directory)
  const noImage = createGitHub(); publishCandidate(noImage, image, { omit: [archiveName(version)] })
  assertRefused(noImage, 'a missing image', directory)
}))

test('missing, wrong or foreign provenance is a hard failure before the image is mounted', darwin, () => inTemp(directory => {
  const image = goodImage()
  const missing = createGitHub(); publishCandidate(missing, image, { attestDmg: false })
  assertRefused(missing, 'a DMG nobody attested', directory)
  const manifestOnly = createGitHub(); publishCandidate(manifestOnly, image, { attestManifest: false })
  assertRefused(manifestOnly, 'an unattested manifest', directory)
  const tampered = createGitHub(); const { name } = publishCandidate(tampered, image)
  const flipped = Buffer.from(image.bytes); flipped[Math.floor(flipped.length / 2)] ^= 0xff
  tampered.state.files.get(name)?.set(archiveName(version), flipped)
  assertRefused(tampered, 'a DMG whose bytes differ from the attested ones', directory)
  const appended = createGitHub(); const second = publishCandidate(appended, image)
  appended.state.files.get(second.name)?.set(archiveName(version), Buffer.concat([image.bytes, Buffer.from([0])]))
  assertRefused(appended, 'a DMG with an appended byte', directory)
  const otherCommit = createGitHub(); publishCandidate(otherCommit, image, { attestDmg: false }); otherCommit.attest(image.bytes, { sourceRepositoryDigest: 'd'.repeat(40), buildSignerDigest: 'd'.repeat(40) })
  assertRefused(otherCommit, 'provenance of another commit', directory)
  const otherRef = createGitHub(); publishCandidate(otherRef, image, { attestDmg: false }); otherRef.attest(image.bytes, { sourceRepositoryRef: 'refs/heads/feature' })
  assertRefused(otherRef, 'provenance of another ref', directory)
  const selfHosted = createGitHub(); publishCandidate(selfHosted, image, { attestDmg: false }); selfHosted.attest(image.bytes, { runnerEnvironment: 'self-hosted' })
  assertRefused(selfHosted, 'provenance from a self-hosted runner', directory)
  const otherWorkflow = createGitHub(); publishCandidate(otherWorkflow, image, { attestDmg: false })
  otherWorkflow.attest(image.bytes, { subjectAlternativeName: `https://github.com/${repository}/.github/workflows/verify.yml@refs/heads/main` })
  assertRefused(otherWorkflow, 'provenance of another workflow', directory)
  // The policy flags cannot tell runs apart; the printed certificate is what binds the exact run and attempt.
  const otherRun = createGitHub(); publishCandidate(otherRun, image, { attestDmg: false }); otherRun.attest(image.bytes, {}, { runId: 9000 })
  assertRefused(otherRun, 'provenance of another run of the same commit', directory)
  const otherAttempt = createGitHub(); publishCandidate(otherAttempt, image, { attestDmg: false }); otherAttempt.attest(image.bytes, {}, { attempt: 2 })
  assertRefused(otherAttempt, 'provenance of another attempt', directory)
}))

test('a manifest that disagrees with the authenticated run or the image is refused even when attested', darwin, () => inTemp(directory => {
  const image = goodImage()
  /** @type {[string, Record<string, unknown>][]} */
  const lies = [
    ['another commit', { sourceCommit: 'd'.repeat(40) }], ['another attempt', { runAttempt: 2 }], ['another run', { runId: '9000' }], ['another event', { event: 'push' }],
    ['another ref', { ref: 'refs/heads/feature' }], ['another repository', { repository: 'other/omp-usage-panel' }], ['another version', { version: '9.9.9' }],
    ['another length', { length: image.bytes.length + 1 }], ['another archive hash', { archiveSHA256: sha256('other') }],
    ['an unknown field', { release: 'true' }],
  ]
  for (const [label, manifest] of lies) {
    const github = createGitHub(); publishCandidate(github, image, { manifest })
    assertRefused(github, label, directory)
  }
  const github = createGitHub(); publishCandidate(github, image, { manifest: { appTreeSHA256: '0'.repeat(64) } })
  assertRefused(github, 'a tree hash that is not the image\'s', directory, { attaches: true })
}))

test('a run that is re-run or changes while its candidate is being authenticated is refused before the bytes are used', darwin, () => inTemp(directory => {
  const image = goodImage()
  const rerun = createGitHub(); publishCandidate(rerun, image)
  rerun.state.afterDownload = () => { rerun.state.run.run_attempt = 2 }
  assertRefused(rerun, 'a new attempt of the run started after the download', directory)
  const running = createGitHub(); publishCandidate(running, image)
  running.state.afterDownload = () => { running.state.run.run_attempt = 2; running.state.run.status = 'in_progress'; running.state.run.conclusion = null }
  assertRefused(running, 'a re-run that is still running', directory)
}))

test('an attested image whose content is not the expected release is refused after provenance', darwin, () => inTemp(directory => {
  const thin = createGitHub(); publishCandidate(thin, otherImage(directory, { universal: false }))
  assertRefused(thin, 'a single-architecture app', directory, { attaches: true })
  const old = createGitHub(); publishCandidate(old, otherImage(directory, { version: '0.9.0' }))
  assertRefused(old, 'an app of another version', directory, { attaches: true })
}))

test('packaging imports only the run of the expected commit and version, and calls the body only after authentication', darwin, () => inTemp(directory => {
  const image = goodImage(), github = createGitHub(); publishCandidate(github, image)
  /** @param {{version?: string, head?: string}} expected */
  const attempt = expected => { let reached = false; try { withVerifiedCandidate({ runId: '9001', version, head, gh: github.gh, temporaryRoot: directory, ...expected }, () => { reached = true }) } finally { assert.equal(reached, expected.head === undefined && expected.version === undefined) } }
  attempt({})
  assert.throws(() => attempt({ head: 'd'.repeat(40) }), 'a candidate of an older commit than the checked-out HEAD')
  assert.throws(() => attempt({ version: '9.9.9' }), 'a candidate of another version than package.json')
  const seen = withVerifiedCandidate({ runId: '9001', version, head, gh: github.gh, temporaryRoot: directory }, candidate => ({ bytes: readFileSync(candidate.archivePath), sha256: candidate.sha256, provenance: candidate.provenance, commit: candidate.manifest.sourceCommit }))
  assert.ok(seen.bytes.equals(image.bytes), 'the body receives the attested bytes untouched')
  assert.equal(seen.sha256, sha256(image.bytes)); assert.equal(seen.commit, head)
  assert.deepEqual(seen.provenance, { repository, workflow: workflowPath, runId: '9001', runAttempt: 1, event: 'workflow_dispatch', ref: 'refs/heads/main', artifact: artifactName({ sourceCommit: head, runId: 9001, runAttempt: 1 }) })
  assert.throws(() => withVerifiedCandidate({ runId: 'latest', gh: github.gh, temporaryRoot: directory }, () => 0), 'a run that is not an id')
}))

/** @type {NodeJS.ProcessEnv} */
const trustedEnv = {
  GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository, GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/main', GITHUB_SHA: head,
  GITHUB_WORKFLOW_REF: `${repository}/${workflowPath}@refs/heads/main`, RUNNER_ENVIRONMENT: 'github-hosted', GITHUB_RUN_ID: '9001', GITHUB_RUN_ATTEMPT: '1',
}

test('a built candidate holds exactly the DMG and its manifest, publishes the step outputs and verifies through the consumer path', darwin, async () => inTemp(async directory => {
  const app = buildFixtureApp(directory, { version }), output = path.join(directory, 'ci-release'), outputs = path.join(directory, 'github-output')
  const built = await buildCandidate({ output, env: { ...trustedEnv, GITHUB_OUTPUT: outputs }, withApp: async (_options, body) => body({ app, appTreeHash, sourceCommit: head }), nodePin: fixtureNodePin })
  assert.deepEqual(readdirSync(output).sort(), [archiveName(version), candidateManifestName].sort(), 'no build tree or scratch files are left in the artifact')
  const dmg = readFileSync(path.join(output, archiveName(version))), manifestBytes = readFileSync(path.join(output, candidateManifestName))
  const manifest = parseCandidate(manifestBytes.toString('utf8'))
  assert.deepEqual(manifest, built.manifest)
  assert.deepEqual({ ...manifest }, {
    schema: 1, repository, workflow: workflowPath, event: 'workflow_dispatch', ref: 'refs/heads/main', sourceCommit: head, runId: '9001', runAttempt: 1, version, archiveName: archiveName(version),
    length: dmg.length, archiveSHA256: sha256(dmg), appTreeSHA256: appTreeHash(app),
  })
  const lines = Object.fromEntries(readFileSync(outputs, 'utf8').split('\n').filter(Boolean).map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]))
  assert.deepEqual(lines, {
    'artifact-name': artifactName({ sourceCommit: head, runId: 9001, runAttempt: 1 }), 'archive-name': archiveName(version), 'archive-sha256': sha256(dmg),
    'manifest-name': candidateManifestName, 'manifest-sha256': sha256(manifestBytes),
  })
  // What the workflow uploads and attests is what the local verifier accepts.
  const github = createGitHub()
  const name = lines['artifact-name'] ?? ''
  github.state.artifacts.push({ id: 1, name, size_in_bytes: dmg.length, expired: false, workflow_run: { id: 9001, head_branch: 'main', head_sha: head } })
  github.state.files.set(name, new Map([[archiveName(version), dmg], [candidateManifestName, manifestBytes]]))
  github.attest(dmg); github.attest(manifestBytes)
  const verified = verifyCandidateRun({ runId: '9001', appTreeHash, gh: github.gh, temporaryRoot: directory })
  assert.equal(verified.archiveSHA256, sha256(dmg)); assert.equal(verified.appTreeSHA256, appTreeHash(app))
}))

test('a candidate is not built for an untrusted trigger, another commit, a dirty checkout, a wrong app version, an app without the bundled Node runtime or an existing output, and leaves nothing behind', darwin, async () => inTemp(async directory => {
  const app = buildFixtureApp(directory, { version })
  /** @param {string | undefined} commit @returns {import('./ci-release.mjs').CandidateAppProvider} */
  const provide = commit => async (_options, body) => body({ app, appTreeHash, sourceCommit: commit })
  /** @param {string} label @param {Parameters<typeof buildCandidate>[0]} options */
  const refuses = async (label, options) => {
    const output = path.join(directory, `out-${label.replace(/\W+/g, '-')}`)
    await assert.rejects(buildCandidate({ ...options, output, nodePin: fixtureNodePin }), label)
    assert.equal(existsSync(output), false, `${label}: no candidate directory`)
    assert.deepEqual(readdirSync(directory).filter(name => name.startsWith('.omp-ci-')), [], `${label}: no staging directory`)
  }
  let built = false
  await refuses('pull request', { env: { ...trustedEnv, GITHUB_EVENT_NAME: 'pull_request' }, withApp: async (_options, body) => { built = true; return body({ app, appTreeHash, sourceCommit: head }) } })
  assert.equal(built, false, 'nothing is built for an untrusted trigger')
  await refuses('other commit', { env: trustedEnv, withApp: provide('d'.repeat(40)) })
  await refuses('dirty tree', { env: trustedEnv, withApp: provide(undefined) })
  await refuses('wrong app version', { env: trustedEnv, withApp: async (_options, body) => body({ app: buildFixtureApp(directory, { version: '0.0.1' }), appTreeHash, sourceCommit: head }) })
  await assert.rejects(buildCandidate({ env: trustedEnv, output: path.join(directory, 'out-no-node'), nodePin: fixtureNodePin, withApp: async (_options, body) => body({ app: buildFixtureApp(directory, { version: '0.0.2', bundledNode: false }), appTreeHash, sourceCommit: head }) }), /no bundled Node runtime/)
  assert.equal(existsSync(path.join(directory, 'out-no-node')), false, 'no candidate without the bundled Node runtime')
  assert.deepEqual(readdirSync(directory).filter(name => name.startsWith('.omp-ci-')), [], 'no staging directory')
  const existing = path.join(directory, 'existing'); mkdirSync(existing); writeFileSync(path.join(existing, 'keep'), 'x')
  await assert.rejects(buildCandidate({ output: existing, env: trustedEnv, withApp: provide(head), nodePin: fixtureNodePin }))
  assert.equal(readFileSync(path.join(existing, 'keep'), 'utf8'), 'x', 'an existing output is never touched')
}))
