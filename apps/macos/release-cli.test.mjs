import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { inTemp } from './release-fixtures.mjs'

// The real `release.mjs` entry point as a consumer runs it: a copy of the production modules sits in a throwaway checkout, so the CLI's own
// main, its dynamic import of ci-release.mjs (which statically imports release.mjs again) and its refusal path all run for real.
// `gh` is a PATH stub that refuses authentication; no network, credentials, Keychain or Sparkle SDK are reachable.

const here = path.dirname(fileURLToPath(import.meta.url))
const modules = ['release.mjs', 'ci-release.mjs', 'build.mjs', 'dmg.mjs', 'sparkle.mjs', 'ownership.mjs', 'update-channel.json', 'node-runtime.json']
const authRefusal = 'stub-gh-authentication-refused-3c9d1f'
const feedSentinel = '<!-- feed sentinel: must stay byte-identical -->\n'

/** Environment with no inherited git/node influence and everything user-level redirected into `root`. @param {string} root @param {string} stubs */
function isolatedEnv(root, stubs) {
  const home = path.join(root, 'home')
  mkdirSync(home, { recursive: true })
  return {
    PATH: `${stubs}:/usr/bin:/bin`,
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, '.config'),
    TMPDIR: root,
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_SYSTEM: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_TERMINAL_PROMPT: '0',
    OMP_USAGE_SPARKLE_CACHE: path.join(root, 'sparkle-cache'),
    OMP_USAGE_NODE_CACHE: path.join(root, 'node-cache'),
  }
}

test('package --ci-run refuses on GitHub authentication through the real CLI without side effects', async () => {
  await inTemp(root => {
    const checkout = path.join(root, 'checkout'), origin = path.join(root, 'origin.git'), stubs = path.join(root, 'stubs')
    const output = path.join(root, 'external-output', 'release'), env = isolatedEnv(root, stubs)
    const feed = path.join(checkout, 'updates/appcast.xml'), channel = path.join(checkout, 'apps/macos/update-channel.json')
    mkdirSync(path.join(checkout, 'apps/macos'), { recursive: true }); mkdirSync(path.dirname(feed), { recursive: true }); mkdirSync(stubs)
    for (const name of modules) copyFileSync(path.join(here, name), path.join(checkout, 'apps/macos', name))
    writeFileSync(path.join(checkout, 'package.json'), '{"name":"fixture","version":"1.0.0"}\n')
    writeFileSync(feed, feedSentinel)

    const gh = path.join(stubs, 'gh')
    writeFileSync(gh, `#!/bin/sh\necho ${authRefusal} >&2\nexit 1\n`)
    chmodSync(gh, 0o755)

    /** @param {string[]} args @param {string} cwd */
    const git = (args, cwd) => execFileSync('/usr/bin/git', ['-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', ...args], { cwd, env, stdio: 'pipe', encoding: 'utf8' })
    git(['init', '--bare', '-b', 'main', origin], root)
    git(['init', '-b', 'main'], checkout)
    git(['remote', 'add', 'origin', origin], checkout)
    git(['add', '-A'], checkout)
    git(['commit', '-m', 'fixture'], checkout)
    git(['push', 'origin', 'main'], checkout)
    assert.equal(git(['status', '--porcelain'], checkout), '')

    const channelBefore = readFileSync(channel)
    const result = spawnSync(process.execPath, [path.join(checkout, 'apps/macos/release.mjs'), 'package', '--ci-run', '9001', '--output', output], { cwd: root, env, encoding: 'utf8', timeout: 60_000 })

    assert.equal(result.error, undefined, 'the CLI must not time out')
    assert.equal(result.signal, null)
    assert.equal(result.status, 1)
    assert.ok(result.stderr.includes(authRefusal), `the external authentication failure must reach stderr: ${result.stderr}`)
    assert.equal(result.stdout, '')
    assert.equal(existsSync(output), false)
    assert.equal(existsSync(path.dirname(output)), false)
    assert.equal(existsSync(env.OMP_USAGE_SPARKLE_CACHE), false)
    assert.equal(existsSync(env.OMP_USAGE_NODE_CACHE), false)
    assert.equal(existsSync(path.join(checkout, 'build')), false)
    assert.equal(readFileSync(feed, 'utf8'), feedSentinel)
    assert.deepEqual(readFileSync(channel), channelBefore)
    assert.equal(git(['status', '--porcelain'], checkout), '')
  })
})
