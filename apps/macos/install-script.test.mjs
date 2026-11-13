import test from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// Runs the real install.sh with /bin/sh; curl, hdiutil, uname, sw_vers, id and sleep are PATH stubs, plutil and shasum are the real macOS tools.
const script = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../install.sh')
const darwin = { skip: process.platform !== 'darwin' }
const releaseBase = 'https://github.com/dhkimxx/omp-usage-panel/releases/download'
const dmgBytes = Buffer.from('fixture disk image bytes\n'.repeat(40))
const dmgSha = createHash('sha256').update(dmgBytes).digest('hex')

/** @param {Record<string, unknown>} [overrides] @param {string} [version] */
function releaseJson(overrides = {}, version = '2.3.4') {
  return JSON.stringify({
    tag_name: `v${version}`,
    assets: [{
      name: `OMP-Usage-${version}.dmg`,
      size: dmgBytes.length,
      digest: `sha256:${dmgSha}`,
      browser_download_url: `${releaseBase}/v${version}/OMP-Usage-${version}.dmg`,
    }],
    ...overrides,
  })
}

/** @param {Record<string, unknown>} asset @param {string} [version] */
const withAsset = (asset, version = '2.3.4') => releaseJson({ assets: [{ ...JSON.parse(releaseJson({}, version)).assets[0], ...asset }] }, version)

/** @param {string} file @param {string} body */
function writeExecutable(file, body) {
  writeFileSync(file, `#!/bin/sh\n${body}`)
  chmodSync(file, 0o755)
}

/** @param {string} root */
function createStubs(root) {
  const bin = path.join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  writeExecutable(path.join(bin, 'uname'), 'printf "%s\\n" "${STUB_UNAME:-Darwin}"\n')
  writeExecutable(path.join(bin, 'sw_vers'), 'printf "%s\\n" "${STUB_SWVERS:-14.5}"\n')
  writeExecutable(path.join(bin, 'id'), 'printf "%s\\n" "${STUB_UID:-501}"\n')
  writeExecutable(path.join(bin, 'sleep'), 'exit 0\n')
  // curl: records every call; serves the API fixture or the DMG fixture by URL, honouring -o.
  writeExecutable(path.join(bin, 'curl'), `
out=''
url=''
while [ "$#" -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -H | --proto) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\\n' "$url" >>"$STUB_LOG/curl.log"
case $url in
  https://api.github.com/*) cp "$STUB_FIXTURES/api.json" "$out" ;;
  *) cp "$STUB_FIXTURES/image.dmg" "$out" ;;
esac
`)
  // hdiutil: attach creates the fake app at the mountpoint; detach fails until -force when STUB_DETACH_FAIL=1.
  writeExecutable(path.join(bin, 'hdiutil'), `
printf '%s\\n' "$*" >>"$STUB_LOG/hdiutil.log"
action=$1
shift
case $action in
  attach)
    mnt=''
    while [ "$#" -gt 0 ]; do
      case $1 in -mountpoint) mnt=$2; shift 2 ;; *) shift ;; esac
    done
    mkdir -p "$mnt/OMP Usage.app/Contents/MacOS"
    cp "$STUB_FIXTURES/app-template" "$mnt/OMP Usage.app/Contents/MacOS/OMPUsagePanel"
    chmod 755 "$mnt/OMP Usage.app/Contents/MacOS/OMPUsagePanel"
    ;;
  detach)
    if [ "\${STUB_DETACH_FAIL:-0}" = 1 ]; then
      case " $* " in *" -force "*) exit 0 ;; *) exit 1 ;; esac
    fi
    ;;
esac
exit 0
`)
  return bin
}

/**
 * @param {string[]} args
 * @param {{ api?: string, env?: Record<string, string>, appExit?: number }} [options]
 */
function runInstaller(args, options = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'omp-install-test-'))
  const fixtures = path.join(root, 'fixtures')
  const log = path.join(root, 'log')
  const tmp = path.join(root, 'tmp')
  for (const directory of [fixtures, log, tmp]) mkdirSync(directory)
  writeFileSync(path.join(fixtures, 'api.json'), options.api ?? releaseJson())
  writeFileSync(path.join(fixtures, 'image.dmg'), dmgBytes)
  writeFileSync(path.join(fixtures, 'app-template'), `#!/bin/sh\nprintf '%s\\n' "$@" >>"$STUB_LOG/app.args"\necho "OMP Usage installed: /Applications/OMP Usage.app"\nexit ${options.appExit ?? 0}\n`)
  const bin = createStubs(root)
  const result = spawnSync('/bin/sh', [script, ...args], {
    encoding: 'utf8',
    env: {
      PATH: `${bin}:/usr/bin:/bin`,
      HOME: path.join(root, 'home'),
      TMPDIR: tmp,
      STUB_LOG: log,
      STUB_FIXTURES: fixtures,
      ...options.env,
    },
  })
  /** @param {string} name */
  const lines = name => existsSync(path.join(log, name)) ? readFileSync(path.join(log, name), 'utf8').split('\n').filter(Boolean) : []
  const outcome = {
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
    curl: lines('curl.log'),
    hdiutil: lines('hdiutil.log'),
    appArgs: lines('app.args'),
    leftovers: readdirSync(tmp),
  }
  rmSync(root, { recursive: true, force: true })
  return outcome
}

/** @param {ReturnType<typeof runInstaller>} outcome */
const attaches = outcome => outcome.hdiutil.filter(line => line.startsWith('attach'))
/** @param {ReturnType<typeof runInstaller>} outcome */
const detaches = outcome => outcome.hdiutil.filter(line => line.startsWith('detach'))
/** @param {ReturnType<typeof runInstaller>} outcome */
const downloads = outcome => outcome.curl.filter(url => !url.startsWith('https://api.github.com/'))

/** @param {ReturnType<typeof runInstaller>} outcome */
function assertRefusedBeforeMount(outcome) {
  assert.equal(outcome.status, 1, outcome.stderr)
  assert.deepEqual(attaches(outcome), [])
  assert.deepEqual(outcome.appArgs, [])
  assert.deepEqual(outcome.leftovers, [])
}

test('installs the latest release, forwards options, detaches and cleans up', darwin, () => {
  const outcome = runInstaller(['--omp', '/opt/bin/omp', '--profile', 'work'])
  assert.equal(outcome.status, 0, outcome.stderr)
  assert.equal(outcome.curl[0], 'https://api.github.com/repos/dhkimxx/omp-usage-panel/releases/latest')
  assert.deepEqual(downloads(outcome), [`${releaseBase}/v2.3.4/OMP-Usage-2.3.4.dmg`])
  assert.equal(attaches(outcome).length, 1)
  assert.match(attaches(outcome)[0], /-readonly -nobrowse -noverify -noautoopen -mountpoint \S+\/mnt \S+\/OMP-Usage\.dmg$/)
  assert.deepEqual(outcome.appArgs, ['--install', '--omp', '/opt/bin/omp', '--profile', 'work'])
  assert.equal(detaches(outcome).length, 1)
  assert.match(outcome.stdout, /OMP Usage installed: \/Applications\/OMP Usage\.app/)
  assert.match(outcome.stdout, /LaunchAgent/)
  assert.deepEqual(outcome.leftovers, [])
})

test('passes only --install when no options are given', darwin, () => {
  const outcome = runInstaller([])
  assert.equal(outcome.status, 0, outcome.stderr)
  assert.deepEqual(outcome.appArgs, ['--install'])
})

test('--version and OMP_USAGE_VERSION pin the tags endpoint', darwin, () => {
  const viaFlag = runInstaller(['--version', '1.0.0'], { api: releaseJson({}, '1.0.0') })
  assert.equal(viaFlag.status, 0, viaFlag.stderr)
  assert.equal(viaFlag.curl[0], 'https://api.github.com/repos/dhkimxx/omp-usage-panel/releases/tags/v1.0.0')
  const viaEnv = runInstaller([], { api: releaseJson({}, '1.0.0'), env: { OMP_USAGE_VERSION: '1.0.0' } })
  assert.equal(viaEnv.status, 0, viaEnv.stderr)
  assert.equal(viaEnv.curl[0], 'https://api.github.com/repos/dhkimxx/omp-usage-panel/releases/tags/v1.0.0')
})

test('a pinned version refuses a release with a different tag', darwin, () => {
  const outcome = runInstaller(['--version', '1.0.0'], { api: releaseJson({}, '2.3.4') })
  assertRefusedBeforeMount(outcome)
  assert.deepEqual(downloads(outcome), [])
})

test('sha256 mismatch aborts before mounting and cleans up', darwin, () => {
  const outcome = runInstaller([], { api: withAsset({ digest: `sha256:${'0'.repeat(64)}` }) })
  assertRefusedBeforeMount(outcome)
  assert.equal(downloads(outcome).length, 1)
  assert.match(outcome.stderr, /SHA-256/)
})

test('size mismatch aborts before mounting and cleans up', darwin, () => {
  const outcome = runInstaller([], { api: withAsset({ size: dmgBytes.length + 1 }) })
  assertRefusedBeforeMount(outcome)
  assert.equal(downloads(outcome).length, 1)
  assert.match(outcome.stderr, /size/)
})

/** @type {Array<[string, string]>} */
const refusedReleases = [
  ['no assets', releaseJson({ assets: [] })],
  ['missing assets key', JSON.stringify({ tag_name: 'v2.3.4' })],
  ['two assets', releaseJson({ assets: [JSON.parse(releaseJson()).assets[0], JSON.parse(releaseJson()).assets[0]] })],
  ['misnamed asset', withAsset({ name: 'OMP-Usage-9.9.9.dmg' })],
  ['asset name with a path', withAsset({ name: '../OMP-Usage-2.3.4.dmg' })],
  ['non-GitHub download URL', withAsset({ browser_download_url: 'https://example.com/releases/download/v2.3.4/OMP-Usage-2.3.4.dmg' })],
  ['look-alike download host', withAsset({ browser_download_url: 'https://github.com.evil.test/dhkimxx/omp-usage-panel/releases/download/v2.3.4/OMP-Usage-2.3.4.dmg' })],
  ['download URL with shell metacharacters', withAsset({ browser_download_url: `${releaseBase}/v2.3.4/OMP-Usage-2.3.4.dmg;touch x` })],
  ['plain http download URL', withAsset({ browser_download_url: 'http://github.com/dhkimxx/omp-usage-panel/releases/download/v2.3.4/OMP-Usage-2.3.4.dmg' })],
  ['missing digest', releaseJson({ assets: [{ name: 'OMP-Usage-2.3.4.dmg', size: dmgBytes.length, browser_download_url: `${releaseBase}/v2.3.4/OMP-Usage-2.3.4.dmg` }] })],
  ['non-sha256 digest', withAsset({ digest: 'sha1:da39a3ee5e6b4b0d3255bfef95601890afd80709' })],
  ['short digest', withAsset({ digest: 'sha256:abcd' })],
  ['uppercase digest', withAsset({ digest: `sha256:${dmgSha.toUpperCase()}` })],
  ['non-numeric size', withAsset({ size: '12abc' })],
  ['tag without v prefix', releaseJson({ tag_name: '2.3.4' })],
  ['malformed version', releaseJson({ tag_name: 'v2.3' })],
  ['version with a pre-release suffix', releaseJson({ tag_name: 'v2.3.4-beta' })],
  ['invalid JSON', 'not json'],
]
for (const [name, api] of refusedReleases) {
  test(`refuses release metadata: ${name}`, darwin, () => {
    const outcome = runInstaller([], { api })
    assertRefusedBeforeMount(outcome)
    assert.deepEqual(downloads(outcome), [], 'must not download unverified assets')
  })
}

test('refuses a non-Darwin system', darwin, () => {
  const outcome = runInstaller([], { env: { STUB_UNAME: 'Linux' } })
  assertRefusedBeforeMount(outcome)
  assert.deepEqual(outcome.curl, [])
  assert.match(outcome.stderr, /macOS/)
})

test('refuses macOS 12', darwin, () => {
  const outcome = runInstaller([], { env: { STUB_SWVERS: '12.7.6' } })
  assertRefusedBeforeMount(outcome)
  assert.deepEqual(outcome.curl, [])
  assert.match(outcome.stderr, /macOS 13/)
})

test('accepts macOS 13', darwin, () => {
  assert.equal(runInstaller([], { env: { STUB_SWVERS: '13.0' } }).status, 0)
})

test('refuses to run as root', darwin, () => {
  const outcome = runInstaller([], { env: { STUB_UID: '0' } })
  assertRefusedBeforeMount(outcome)
  assert.deepEqual(outcome.curl, [])
  assert.match(outcome.stderr, /root/)
})

test('a failing app installer propagates its exit code and still detaches and cleans up', darwin, () => {
  const outcome = runInstaller([], { appExit: 3 })
  assert.equal(outcome.status, 3)
  assert.deepEqual(outcome.appArgs, ['--install'])
  assert.equal(detaches(outcome).length, 1)
  assert.deepEqual(outcome.leftovers, [])
  assert.doesNotMatch(outcome.stdout, /LaunchAgent/)
})

test('detach is retried and then forced; the temp dir is still removed', darwin, () => {
  const outcome = runInstaller([], { env: { STUB_DETACH_FAIL: '1' } })
  assert.equal(outcome.status, 0, outcome.stderr)
  const lines = detaches(outcome)
  assert.equal(lines.length, 4)
  assert.ok(lines.slice(0, 3).every(line => !line.includes('-force')))
  assert.match(lines[3], /-force/)
  assert.deepEqual(outcome.leftovers, [])
})

test('unknown options and malformed arguments exit 2 without any side effect', darwin, () => {
  for (const args of [['--bogus'], ['--omp'], ['--profile'], ['--version'], ['--version', 'latest'], ['--version', '1.2'], ['--omp', 'relative/omp'], ['--profile', ''], ['positional']]) {
    const outcome = runInstaller(args)
    assert.equal(outcome.status, 2, `${args.join(' ')}: ${outcome.stderr}`)
    assert.match(outcome.stderr, /Usage:/)
    assert.deepEqual(outcome.curl, [])
    assert.deepEqual(outcome.hdiutil, [])
    assert.deepEqual(outcome.leftovers, [])
  }
})

test('--help prints usage to stdout and exits 0 without side effects', darwin, () => {
  const outcome = runInstaller(['--help'])
  assert.equal(outcome.status, 0)
  assert.match(outcome.stdout, /Usage: install\.sh/)
  assert.deepEqual(outcome.curl, [])
  assert.deepEqual(outcome.hdiutil, [])
})
