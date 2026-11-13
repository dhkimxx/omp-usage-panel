import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { appendFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DmgCleanupError, createDmg } from './dmg.mjs'
import { archiveName, inspectArchive, removeTemporaryTree, withReleaseApp, withTemporaryDirectory } from './release.mjs'
import { defaults, rootVersion, sourceRoot } from './sparkle.mjs'

// GitHub-hosted candidate build and local authentication of its exact bytes.
//
// `build` runs only inside the Package workflow: it builds the universal DMG from a clean snapshot of the triggering commit and writes
// `candidate.json` beside it. The workflow's second job attests both files with GitHub's keyless build provenance. Nothing here signs updates,
// holds a key, or publishes anything.
//
// `withVerifiedCandidate` (used by `release:verify-ci` and `release:package -- --ci-run`) is the only way the DMG leaves GitHub: the run, its
// artifact and the DMG's provenance attestation are authenticated through the GitHub API and `gh attestation verify` BEFORE the image is mounted
// or signed. `candidate.json` is never authority; it is cross-checked against the authenticated run and the DMG bytes.

const usage = `Usage:
  node apps/macos/ci-release.mjs build [--output directory]
  node apps/macos/ci-release.mjs verify --run id`

export const workflowPath = '.github/workflows/package.yml'
export const candidateManifestName = 'candidate.json'
export const defaultOutput = path.join(sourceRoot, 'build/ci-release')
const attestationIssuer = 'https://token.actions.githubusercontent.com'
const maxArchiveBytes = 512 * 1024 * 1024, maxManifestBytes = 64 * 1024

/** @typedef {import('./release.mjs').TreeHash} TreeHash */
/** @typedef {(args: string[]) => string} Gh  Runs the GitHub CLI and returns its stdout; a failure throws an Error whose `stderr` carries the CLI's message. */
/** @typedef {'workflow_dispatch' | 'push'} TrustedEvent */
/** @typedef {{schema: 1, repository: string, workflow: string, event: TrustedEvent, ref: string, sourceCommit: string, runId: string, runAttempt: number, version: string, archiveName: string, length: number, archiveSHA256: string, appTreeSHA256: string}} Candidate */
/** @typedef {import('./dmg.mjs').Hdiutil} Hdiutil */
/** @typedef {{id: number, attempt: number, head: string, event: TrustedEvent, branch: string, ref: string, tagVersion: string | undefined}} TrustedRun */
/** @typedef {(options: {outputDirectory: string, requireClean?: boolean}, body: (built: {app: string, appTreeHash: TreeHash, sourceCommit: string | undefined}) => Candidate) => Promise<Candidate>} CandidateAppProvider */

/** @type {Gh} */
export const systemGh = args => execFileSync('gh', args, {
  encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 300_000, maxBuffer: 64 * 1024 * 1024,
  env: { ...process.env, GH_HOST: 'github.com', GH_PROMPT_DISABLED: '1', NO_COLOR: '1' },
})
/** @param {unknown} error */
function ghDetail(error) {
  const stderr = /** @type {{stderr?: unknown}} */ (error)?.stderr
  return String(typeof stderr === 'string' && stderr.trim() ? stderr : error instanceof Error ? error.message : error).trim()
}
/** @param {Gh} gh @param {string[]} args @param {string} what */
function ghJson(gh, args, what) {
  try { return JSON.parse(gh(args)) } catch (error) { throw new Error(`Could not read ${what} from GitHub: ${ghDetail(error)}`) }
}
/** @param {string | Buffer} data */
const sha256 = data => createHash('sha256').update(data).digest('hex')
/** @param {string} file */
const sha256File = file => sha256(readFileSync(file))

/** Fixed artifact name of one workflow attempt. @param {{sourceCommit: string, runId: string | number, runAttempt: string | number}} identity */
export const artifactName = ({ sourceCommit, runId, runAttempt }) => `macos-release-${sourceCommit}-${runId}-${runAttempt}`

// ---------------------------------------------------------------- manifest
/** @param {Candidate} manifest */
export function renderCandidate(manifest) {
  return `${JSON.stringify({
    schema: manifest.schema, repository: manifest.repository, workflow: manifest.workflow, event: manifest.event, ref: manifest.ref, sourceCommit: manifest.sourceCommit,
    runId: manifest.runId, runAttempt: manifest.runAttempt, version: manifest.version, archiveName: manifest.archiveName, length: manifest.length,
    archiveSHA256: manifest.archiveSHA256, appTreeSHA256: manifest.appTreeSHA256,
  }, null, 2)}\n`
}
const manifestKeys = ['schema', 'repository', 'workflow', 'event', 'ref', 'sourceCommit', 'runId', 'runAttempt', 'version', 'archiveName', 'length', 'archiveSHA256', 'appTreeSHA256']
/**
 * Strictly parses candidate.json: exactly the known fields with the expected shapes.
 * @param {string} text
 * @returns {Candidate}
 */
export function parseCandidate(text) {
  /** @type {unknown} */
  let value
  try { value = JSON.parse(text) } catch { throw new Error('candidate.json is not valid JSON') }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('candidate.json is not a JSON object')
  const fields = /** @type {Record<string, unknown>} */ (value)
  if (Object.keys(fields).sort().join(',') !== [...manifestKeys].sort().join(',')) throw new Error('candidate.json has unexpected or missing fields')
  /** @param {string} name @param {RegExp} pattern */
  const str = (name, pattern) => { const field = fields[name]; if (typeof field !== 'string' || !pattern.test(field)) throw new Error(`candidate.json ${name} is invalid`); return field }
  /** @param {string} name */
  const count = name => { const field = fields[name]; if (typeof field !== 'number' || !Number.isSafeInteger(field) || field < 1) throw new Error(`candidate.json ${name} is invalid`); return field }
  if (fields.schema !== 1) throw new Error('candidate.json schema is unsupported')
  return {
    schema: 1,
    repository: str('repository', /^[\w.-]+\/[\w.-]+$/),
    workflow: str('workflow', /^\.github\/workflows\/[\w.-]+\.ya?ml$/),
    event: /** @type {TrustedEvent} */ (str('event', /^(workflow_dispatch|push)$/)),
    ref: str('ref', /^refs\/(heads|tags)\/[\w./-]+$/),
    sourceCommit: str('sourceCommit', /^[0-9a-f]{40}$/),
    runId: str('runId', /^[1-9]\d{0,17}$/),
    runAttempt: count('runAttempt'),
    version: str('version', /^\d+\.\d+\.\d+$/),
    archiveName: str('archiveName', /^OMP-Usage-\d+\.\d+\.\d+\.dmg$/),
    length: count('length'),
    archiveSHA256: str('archiveSHA256', /^[0-9a-f]{64}$/),
    appTreeSHA256: str('appTreeSHA256', /^[0-9a-f]{64}$/),
  }
}

// ---------------------------------------------------------------- build (inside the GitHub-hosted workflow)
/**
 * The only triggers a candidate is built for: a manual run on main, or a push of the tag `v<package version>`, in the canonical repository,
 * by the Package workflow itself, on a GitHub-hosted runner. Everything comes from the runner's own environment.
 * @param {NodeJS.ProcessEnv} env @param {string} version
 */
export function trustedTrigger(env, version) {
  if (env.GITHUB_ACTIONS !== 'true') throw new Error('A CI candidate is built only inside the GitHub-hosted Package workflow')
  const repository = env.GITHUB_REPOSITORY, event = env.GITHUB_EVENT_NAME, ref = env.GITHUB_REF ?? '', sourceCommit = env.GITHUB_SHA ?? ''
  if (repository !== defaults.repository) throw new Error(`Candidates are built only in ${defaults.repository}, not ${repository}`)
  if (env.RUNNER_ENVIRONMENT !== 'github-hosted') throw new Error('Candidates are built only on GitHub-hosted runners')
  if (env.GITHUB_WORKFLOW_REF !== `${repository}/${workflowPath}@${ref}`) throw new Error(`Candidates are built only by ${workflowPath}, not ${env.GITHUB_WORKFLOW_REF}`)
  if (event === 'workflow_dispatch') { if (ref !== 'refs/heads/main') throw new Error(`Manual candidates are built only on main, not ${ref}`) }
  else if (event === 'push') { if (ref !== `refs/tags/v${version}`) throw new Error(`Tag candidates are built only for refs/tags/v${version}, not ${ref}`) }
  else throw new Error(`Candidates are not built for ${event} events`)
  if (!/^[0-9a-f]{40}$/.test(sourceCommit)) throw new Error('GITHUB_SHA is not a full commit id')
  const runId = env.GITHUB_RUN_ID ?? '', attempt = env.GITHUB_RUN_ATTEMPT ?? ''
  if (!/^[1-9]\d{0,17}$/.test(runId) || !/^[1-9]\d{0,5}$/.test(attempt)) throw new Error('GITHUB_RUN_ID or GITHUB_RUN_ATTEMPT is not a positive integer')
  return { repository, event: /** @type {TrustedEvent} */ (event), ref, sourceCommit, runId, runAttempt: Number(attempt) }
}

/**
 * Builds the universal DMG candidate from a clean snapshot of the triggering commit, proves it through a read-only mount against the built
 * app (layout, universal deep-signed app, version, tree hash) and writes it with candidate.json into `output`, which must not exist.
 * When the runner provides GITHUB_OUTPUT, the artifact name and the SHA-256 of both files are published as step outputs so later jobs can
 * require exactly these bytes.
 * @param {{output?: string | undefined, env?: NodeJS.ProcessEnv, withApp?: CandidateAppProvider, nodePin?: import('./sparkle.mjs').NodePin}} [options]  `withApp` supplies the built app; tests replace the compiler-backed default. `nodePin` replaces the committed Node pin the bundled runtime is checked against (tests).
 * @returns {Promise<{output: string, manifest: Candidate, manifestSHA256: string}>}
 */
export async function buildCandidate({ output = defaultOutput, env = process.env, withApp = withReleaseApp, nodePin } = {}) {
  const version = rootVersion(), trigger = trustedTrigger(env, version)
  const target = path.resolve(output)
  if (existsSync(target)) throw new Error(`Candidate output already exists: ${target}`)
  const parent = path.dirname(target); mkdirSync(parent, { recursive: true })
  const stage = mkdtempSync(path.join(parent, '.omp-ci-'))
  try {
    const manifest = await withApp({ outputDirectory: path.join(stage, 'build'), requireClean: true }, ({ app, appTreeHash, sourceCommit }) => {
      if (sourceCommit === undefined) throw new Error('The candidate must be built from a clean checkout of the pinned commit')
      if (sourceCommit !== trigger.sourceCommit) throw new Error(`The checked-out commit ${sourceCommit} is not the commit that triggered this run (${trigger.sourceCommit})`)
      const archive = path.join(stage, archiveName(version))
      createDmg({ app, output: archive })
      const appTreeSHA256 = inspectArchive({ file: archive, version, appTreeHash, expectedAppTreeSHA256: appTreeHash(app), expectedFrom: 'the built app', requireBundledNode: true, nodePin })
      const bytes = readFileSync(archive)
      /** @type {Candidate} */
      const built = {
        schema: 1, repository: trigger.repository, workflow: workflowPath, event: trigger.event, ref: trigger.ref, sourceCommit, runId: trigger.runId, runAttempt: trigger.runAttempt,
        version, archiveName: archiveName(version), length: bytes.length, archiveSHA256: sha256(bytes), appTreeSHA256,
      }
      return built
    })
    removeTemporaryTree(path.join(stage, 'build'))
    const text = renderCandidate(manifest)
    writeFileSync(path.join(stage, candidateManifestName), text)
    renameSync(stage, target)
    const manifestSHA256 = sha256(text)
    if (env.GITHUB_OUTPUT) {
      appendFileSync(env.GITHUB_OUTPUT, [
        `artifact-name=${artifactName(manifest)}`, `archive-name=${manifest.archiveName}`, `archive-sha256=${manifest.archiveSHA256}`,
        `manifest-name=${candidateManifestName}`, `manifest-sha256=${manifestSHA256}`, '',
      ].join('\n'))
    }
    return { output: target, manifest, manifestSHA256 }
  } catch (error) {
    // An image that may still be attached keeps its staging directory; anything else is removed without ever crossing into a mounted volume.
    if (!(error instanceof DmgCleanupError)) {
      try { removeTemporaryTree(stage) } catch (cleanup) { console.error(`Could not remove ${stage}: ${cleanup instanceof Error ? cleanup.message : cleanup}`) }
    }
    throw error
  }
}

// ---------------------------------------------------------------- authentication (local, read-only)
/**
 * Policy for the GitHub API's run object: only a completed, successful Package run of this repository itself, triggered by a manual dispatch
 * on main or by a version tag, and (when `head` is given) built from exactly that commit.
 * @param {any} run  @param {{runId: string, head?: string | undefined, repository?: string}} expected
 * @returns {TrustedRun}
 */
export function trustedRun(run, { runId, head, repository = defaults.repository }) {
  /** @param {string} reason @returns {never} */
  function refuse(reason) { throw new Error(`Run ${runId} is not a trusted Package run: ${reason}`) }
  if (String(run?.id) !== runId) return refuse('GitHub returned a different run')
  if (run.repository?.full_name !== repository || run.head_repository?.full_name !== repository || run.head_repository?.fork !== false) return refuse(`it did not run in ${repository} itself`)
  /** The API reports a run's workflow either as the bare file path or suffixed with the ref it ran on. @param {string} ref */
  const ranWorkflow = ref => run.path === workflowPath || run.path === `${workflowPath}@${ref}`
  if (run.status !== 'completed' || run.conclusion !== 'success') return refuse(`it is ${run.status}/${run.conclusion}, not completed/success`)
  const attempt = run.run_attempt
  if (typeof attempt !== 'number' || !Number.isSafeInteger(attempt) || attempt < 1) return refuse('it has no valid attempt number')
  const sha = run.head_sha
  if (typeof sha !== 'string' || !/^[0-9a-f]{40}$/.test(sha)) return refuse('it has no valid commit')
  if (head !== undefined && sha !== head) return refuse(`it built ${sha}, not ${head}`)
  const branch = run.head_branch
  if (run.event === 'workflow_dispatch') {
    if (branch !== 'main') return refuse(`manual runs are trusted only on main, not ${branch}`)
    if (!ranWorkflow('refs/heads/main')) return refuse(`it ran ${run.path}, not ${workflowPath}`)
    return { id: Number(runId), attempt, head: sha, event: 'workflow_dispatch', branch, ref: 'refs/heads/main', tagVersion: undefined }
  }
  if (run.event === 'push') {
    const tag = /^v(\d+\.\d+\.\d+)$/.exec(typeof branch === 'string' ? branch : '')
    if (!tag) return refuse(`push runs are trusted only for version tags, not ${branch}`)
    if (!ranWorkflow(`refs/tags/${branch}`)) return refuse(`it ran ${run.path}, not ${workflowPath}`)
    return { id: Number(runId), attempt, head: sha, event: 'push', branch, ref: `refs/tags/${branch}`, tagVersion: tag[1] }
  }
  return refuse(`${run.event} runs are not trusted`)
}

/**
 * Exactly one live artifact of this attempt, belonging to this run and commit.
 * @param {Gh} gh @param {string} repository @param {TrustedRun} run @param {string} name
 */
function requireArtifact(gh, repository, run, name) {
  const listing = ghJson(gh, ['api', `repos/${repository}/actions/runs/${run.id}/artifacts?name=${encodeURIComponent(name)}&per_page=100`], `the artifacts of run ${run.id}`)
  /** @type {any[]} */
  const matches = (Array.isArray(listing?.artifacts) ? listing.artifacts : []).filter((/** @type {any} */ artifact) => artifact?.name === name)
  if (!matches.length) throw new Error(`Run ${run.id} attempt ${run.attempt} has no artifact named ${name} (a stale or earlier attempt is never used)`)
  if (matches.length > 1) throw new Error(`Run ${run.id} has ${matches.length} artifacts named ${name}; refusing an ambiguous candidate`)
  const [artifact] = matches, origin = artifact.workflow_run
  if (artifact.expired !== false) throw new Error(`Artifact ${name} has expired`)
  if (String(origin?.id) !== String(run.id) || origin?.head_sha !== run.head || origin?.head_branch !== run.branch) throw new Error(`Artifact ${name} does not belong to run ${run.id} at ${run.head}`)
  if (typeof artifact.size_in_bytes !== 'number' || artifact.size_in_bytes > maxArchiveBytes + maxManifestBytes + 1024 * 1024) throw new Error(`Artifact ${name} has an implausible size`)
}

/** Version declared by package.json at the authenticated commit. @param {Gh} gh @param {string} repository @param {string} head */
function sourceVersion(gh, repository, head) {
  let text
  try { text = gh(['api', '-H', 'Accept: application/vnd.github.raw+json', `repos/${repository}/contents/package.json?ref=${head}`]) } catch (error) { throw new Error(`Could not read package.json at ${head}: ${ghDetail(error)}`) }
  /** @type {unknown} */
  let version
  try { version = JSON.parse(text).version } catch { throw new Error(`package.json at ${head} is not valid JSON`) }
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`package.json at ${head} has no MAJOR.MINOR.PATCH version`)
  return version
}

/**
 * The two files of the downloaded artifact, nothing else: the DMG and candidate.json as regular files (no links, no extras).
 * @param {string} directory @param {string} artifact @param {string} version
 */
function candidateFiles(directory, artifact, version) {
  let root = directory
  // `gh run download --name` extracts flat; the artifact's own subdirectory is tolerated.
  const top = readdirSync(directory)
  if (top.length === 1 && top[0] === artifact) {
    root = path.join(directory, artifact)
    if (!lstatSync(root).isDirectory()) throw new Error(`${artifact} in the candidate artifact is not a directory`)
  }
  const expected = [archiveName(version), candidateManifestName], found = readdirSync(root).sort()
  if (found.join('\0') !== [...expected].sort().join('\0')) throw new Error(`The candidate artifact must contain exactly ${expected.join(' and ')}; found ${found.join(', ') || 'nothing'}`)
  for (const name of found) if (!lstatSync(path.join(root, name)).isFile()) throw new Error(`${name} in the candidate artifact is not a regular file`)
  const archivePath = path.join(root, archiveName(version)), manifestPath = path.join(root, candidateManifestName)
  if (statSync(archivePath).size > maxArchiveBytes || statSync(manifestPath).size > maxManifestBytes) throw new Error('The candidate artifact files exceed the size limits')
  return { archivePath, manifestPath }
}

/**
 * Whether one `gh attestation verify --format json` result array holds an attestation that binds `sha256` to this exact run. The certificate
 * fields come from the OIDC token GitHub issued to the workflow job and cannot be set by workflow code; the in-toto subject is the attested digest.
 * @param {unknown} results @param {{sha256: string, run: TrustedRun, repository: string}} expected
 */
export function attestsRun(results, { sha256: digest, run, repository }) {
  if (!Array.isArray(results)) return false
  const base = `https://github.com/${repository}`, workflowURI = `${base}/${workflowPath}@${run.ref}`
  return results.some(entry => {
    const result = entry?.verificationResult, certificate = result?.signature?.certificate, subjects = result?.statement?.subject
    return Boolean(certificate) && Array.isArray(subjects) && subjects.some(subject => subject?.digest?.sha256 === digest) &&
      certificate.issuer === attestationIssuer && certificate.subjectAlternativeName === workflowURI && certificate.buildSignerURI === workflowURI &&
      certificate.githubWorkflowRepository === repository && certificate.githubWorkflowRef === run.ref && certificate.githubWorkflowTrigger === run.event &&
      certificate.sourceRepositoryURI === base && certificate.sourceRepositoryDigest === run.head && certificate.buildSignerDigest === run.head &&
      certificate.sourceRepositoryRef === run.ref && certificate.runnerEnvironment === 'github-hosted' &&
      certificate.runInvocationURI === `${base}/actions/runs/${run.id}/attempts/${run.attempt}`
  })
}

/**
 * Requires GitHub build provenance for one downloaded file: `gh attestation verify` enforces repository, the Package workflow, source and
 * signer commit, ref and GitHub-hosted runner; the printed certificate and subject are then checked against the authenticated run.
 * @param {Gh} gh @param {{file: string, sha256: string, run: TrustedRun, repository: string}} options
 */
function requireAttestation(gh, { file, sha256: digest, run, repository }) {
  const label = path.basename(file)
  let output
  try {
    output = gh([
      'attestation', 'verify', file, '--hostname', 'github.com', '--repo', repository, '--signer-workflow', `${repository}/${workflowPath}`,
      '--source-digest', run.head, '--signer-digest', run.head, '--source-ref', run.ref, '--deny-self-hosted-runners', '--format', 'json',
    ])
  } catch (error) { throw new Error(`GitHub provenance attestation did not verify for ${label}: ${ghDetail(error)}`) }
  /** @type {unknown} */
  let results
  try { results = JSON.parse(output) } catch { throw new Error(`gh attestation verify printed unreadable output for ${label}`) }
  if (!attestsRun(results, { sha256: digest, run, repository })) throw new Error(`No verified attestation binds ${label} to run ${run.id} attempt ${run.attempt} of ${workflowPath} at ${run.head}`)
}

/**
 * @typedef {{archivePath: string, manifest: Candidate, sha256: string, length: number, run: TrustedRun, artifact: string, provenance: Record<string, string | number>}} VerifiedCandidate
 */

/**
 * Downloads one workflow run's candidate into a private temporary directory, authenticates it and runs `body` on it; the directory is removed
 * afterwards (never crossing into a mounted volume). Authentication order: GitHub API run policy -> artifact identity -> exactly two regular
 * files -> provenance attestation of the DMG and candidate.json -> manifest cross-check. The image is NOT mounted here; `body` may do so
 * only because every step before it has passed.
 *
 * With `head` and `version` (local packaging) the run must have built exactly that commit and version; without them (read-only verification)
 * the run's own commit and the package.json version at that commit are used.
 * @template T
 * @param {{runId: string, version?: string | undefined, head?: string | undefined, gh?: Gh, repository?: string, temporaryRoot?: string}} options
 * @param {(candidate: VerifiedCandidate) => T} body
 * @returns {T}
 */
export function withVerifiedCandidate({ runId, version, head, gh = systemGh, repository = defaults.repository, temporaryRoot = tmpdir() }, body) {
  if (!/^[1-9]\d{0,17}$/.test(runId)) throw new Error(`The run must be a GitHub Actions run id, got ${JSON.stringify(runId)}`)
  /** @param {string | undefined} expectedHead */
  const readRun = expectedHead => trustedRun(ghJson(gh, ['api', `repos/${repository}/actions/runs/${runId}`], `run ${runId}`), { runId, head: expectedHead, repository })
  const run = readRun(head)
  const expectedVersion = version ?? sourceVersion(gh, repository, run.head)
  if (run.tagVersion !== undefined && run.tagVersion !== expectedVersion) throw new Error(`Run ${runId} was triggered by tag v${run.tagVersion} but the source version is ${expectedVersion}`)
  const artifact = artifactName({ sourceCommit: run.head, runId: run.id, runAttempt: run.attempt })
  requireArtifact(gh, repository, run, artifact)
  return withTemporaryDirectory(temporaryRoot, 'omp-ci-candidate-', directory => {
    gh(['run', 'download', runId, '--repo', repository, '--name', artifact, '--dir', directory])
    const { archivePath, manifestPath } = candidateFiles(directory, artifact, expectedVersion)
    const manifestBytes = readFileSync(manifestPath), manifestSHA256 = sha256(manifestBytes), archiveSHA256 = sha256File(archivePath), length = statSync(archivePath).size
    requireAttestation(gh, { file: archivePath, sha256: archiveSHA256, run, repository })
    requireAttestation(gh, { file: manifestPath, sha256: manifestSHA256, run, repository })
    const manifest = parseCandidate(manifestBytes.toString('utf8'))
    /** @type {[string, string | number, string | number][]} */
    const claims = [
      ['repository', manifest.repository, repository], ['workflow', manifest.workflow, workflowPath], ['event', manifest.event, run.event], ['ref', manifest.ref, run.ref],
      ['sourceCommit', manifest.sourceCommit, run.head], ['runId', manifest.runId, String(run.id)], ['runAttempt', manifest.runAttempt, run.attempt], ['version', manifest.version, expectedVersion],
      ['archiveName', manifest.archiveName, archiveName(expectedVersion)], ['length', manifest.length, length], ['archiveSHA256', manifest.archiveSHA256, archiveSHA256],
    ]
    const mismatch = claims.find(([, claimed, actual]) => claimed !== actual)
    if (mismatch) throw new Error(`candidate.json ${mismatch[0]} (${mismatch[1]}) does not match the authenticated run (${mismatch[2]})`)
    if (sha256File(archivePath) !== archiveSHA256 || sha256File(manifestPath) !== manifestSHA256) throw new Error('A candidate file changed after it was authenticated')
    // A re-run starts a new attempt (and a new artifact); the run must still be the same completed, successful attempt right before the bytes are used.
    const latest = readRun(run.head)
    if (latest.attempt !== run.attempt || latest.event !== run.event || latest.ref !== run.ref) throw new Error(`Run ${runId} changed while its candidate was being authenticated; retry`)
    return body({
      archivePath, manifest, sha256: archiveSHA256, length, run, artifact,
      provenance: { repository, workflow: workflowPath, runId: String(run.id), runAttempt: run.attempt, event: run.event, ref: run.ref, artifact },
    })
  })
}

/**
 * Read-only verification of one run's candidate: authenticates it, then inspects the DMG through a read-only mount against the manifest's
 * tree hash. Writes nothing, signs nothing and never consults the release state, so an already published version can be verified.
 * `hdiutil` replaces the system tool used to attach the image (the default is `/usr/bin/hdiutil`).
 * @param {{runId: string, appTreeHash: TreeHash, gh?: Gh, temporaryRoot?: string, hdiutil?: Hdiutil | undefined}} options
 */
export function verifyCandidateRun({ runId, appTreeHash, gh = systemGh, temporaryRoot = tmpdir(), hdiutil }) {
  return withVerifiedCandidate({ runId, gh, temporaryRoot }, ({ archivePath, manifest, sha256: archiveSHA256, length, run, artifact }) => {
    const appTreeSHA256 = inspectArchive({ file: archivePath, version: manifest.version, appTreeHash, expectedAppTreeSHA256: manifest.appTreeSHA256, expectedFrom: 'the CI candidate manifest', hdiutil })
    return {
      verified: true, run: run.id, attempt: run.attempt, event: run.event, ref: run.ref, sourceCommit: run.head, version: manifest.version,
      artifact, archiveName: manifest.archiveName, length, archiveSHA256, appTreeSHA256,
      note: 'GitHub build provenance, DMG layout, universal app, version, tree hash and the bundled Node resources (structure and self-consistency only; not compared with the current pin) verified; nothing was signed, written or published',
    }
  })
}

// ---------------------------------------------------------------- command line
/**
 * @param {string[]} args @param {Record<string, 'value'>} flags
 * @returns {Map<string, string>}
 */
function parse(args, flags) {
  const values = /** @type {Map<string, string>} */ (new Map())
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? '', name = arg.replace(/^--/, '')
    if (!arg.startsWith('--') || !flags[name]) throw new Error(usage)
    const value = args[++i]
    if (value === undefined) throw new Error(usage)
    values.set(name, value)
  }
  return values
}
if (import.meta.main) {
  const [command, ...args] = process.argv.slice(2)
  if (command === 'build') {
    const { output, manifest, manifestSHA256 } = await buildCandidate({ output: parse(args, { output: 'value' }).get('output') })
    console.log(JSON.stringify({ output, archivePath: path.join(output, manifest.archiveName), manifestPath: path.join(output, candidateManifestName), manifestSHA256, candidate: manifest }, null, 2))
  } else if (command === 'verify') {
    const runId = parse(args, { run: 'value' }).get('run')
    if (!runId) throw new Error(usage)
    const { appTreeHash } = await import('./ownership.mjs')
    console.log(JSON.stringify(verifyCandidateRun({ runId, appTreeHash }), null, 2))
  } else throw new Error(usage)
}
