import { createHash, sign as cryptoSign } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { dmgAppName } from './dmg.mjs'
import { nodeArches, readNodePin } from './sparkle.mjs'

// Test-only helpers shared by the release tests: a real universal ad-hoc-signed app, an in-process Ed25519 signer standing in for the
// Keychain-backed one, and a temporary directory scope. Needs a macOS host with the Xcode command line tools.

/**
 * Signer with the same contract as the Keychain-backed one: Ed25519 over the exact archive bytes and over the feed text before the signature comment.
 * @param {import('node:crypto').KeyObject} key
 */
export function signerFor(key) {
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

const fakeNode = 'fake node\n'
/**
 * The committed pin with the binary identity of the fixtures' fake `node` file. Release flows that compare the bundled runtime with a pin get
 * it as `nodePin`, so tiny fixtures stay hash-consistent without a real 113 MB Node binary.
 * @type {import('./sparkle.mjs').NodePin}
 */
export const fixtureNodePin = (() => {
  const real = readNodePin(), binary = { size: Buffer.byteLength(fakeNode), sha256: createHash('sha256').update(fakeNode).digest('hex') }
  return { ...real, arches: Object.fromEntries(Object.entries(real.arches).map(([arch, entry]) => [arch, { ...entry, binary }])) }
})()

/**
 * Tiny fake bundled-Node resources consistent with `pin` (default: `fixtureNodePin`): manifest identity (version, team, binary
 * size/SHA-256 of the fake `node` file) over small stand-in archives holding exactly `node` (0755) and `LICENSE`. Never a real Node binary.
 * @param {string} app @param {import('./sparkle.mjs').NodePin} [pin]
 */
export function writeFixtureNodeResources(app, pin = fixtureNodePin) {
  const directory = path.join(app, 'Contents/Resources/node'), scratch = mkdtempSync(path.join(tmpdir(), 'omp-fixture-node-'))
  try {
    mkdirSync(directory, { recursive: true })
    writeFileSync(path.join(scratch, 'node'), fakeNode); chmodSync(path.join(scratch, 'node'), 0o755)
    writeFileSync(path.join(scratch, 'LICENSE'), 'fake license\n')
    /** @type {Record<string, object>} */
    const arches = {}
    for (const arch of nodeArches) {
      const archive = path.join(directory, `node-${arch}.tar.xz`)
      execFileSync('/usr/bin/tar', ['-cJf', archive, '-C', scratch, 'node', 'LICENSE'], { env: { ...process.env, COPYFILE_DISABLE: '1' } })
      const bytes = readFileSync(archive)
      arches[arch] = { archive: `node-${arch}.tar.xz`, archiveSize: bytes.length, archiveSHA256: createHash('sha256').update(bytes).digest('hex'), binarySize: pin.arches[arch].binary.size, binarySHA256: pin.arches[arch].binary.sha256 }
    }
    writeFileSync(path.join(directory, 'manifest.json'), `${JSON.stringify({ schema: 1, version: pin.version, teamIdentifier: pin.teamIdentifier, arches }, null, 2)}\n`)
  } finally { rmSync(scratch, { recursive: true, force: true }) }
}

/**
 * Universal (arm64 + x86_64), ad-hoc deep-signed app. `bundledNode: false` builds an app like the releases published before Node was bundled.
 * @param {string} directory @param {{version?: string, universal?: boolean, bundledNode?: boolean}} [options]
 */
export function buildFixtureApp(directory, { version = '1.0.0', universal = true, bundledNode = true } = {}) {
  const root = path.join(directory, `app-${version}-${universal}`), app = path.join(root, dmgAppName)
  mkdirSync(path.join(app, 'Contents/MacOS'), { recursive: true })
  writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>OMPUsagePanel</string><key>CFBundleIdentifier</key><string>com.example.omp-usage-fixture</string><key>CFBundleName</key><string>OMP Usage</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>${version}</string></dict></plist>\n`)
  const source = path.join(root, 'main.c')
  writeFileSync(source, 'int main(void) { return 0; }\n')
  execFileSync('/usr/bin/xcrun', ['clang', ...(universal ? ['-arch', 'arm64', '-arch', 'x86_64'] : ['-arch', process.arch === 'arm64' ? 'arm64' : 'x86_64']), '-o', path.join(app, 'Contents/MacOS/OMPUsagePanel'), source], { stdio: 'pipe' })
  rmSync(source)
  mkdirSync(path.join(app, 'Contents/Resources')); writeFileSync(path.join(app, 'Contents/Resources/data.txt'), 'resource')
  if (bundledNode) writeFixtureNodeResources(app)
  execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', app], { stdio: 'pipe' })
  return app
}

/** @param {(directory: string) => void | Promise<void>} body */
export async function inTemp(body) {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-release-test-'))
  try { await body(directory) } finally { rmSync(directory, { recursive: true, force: true }) }
}

/**
 * The real hdiutil, recording the image path of every `attach` it performs: a real boundary observation (nothing is faked), so a test can prove
 * that an image was or was not attached.
 */
export function recordingHdiutil() {
  /** @type {string[]} */
  const attached = []
  /** @type {import('./dmg.mjs').Hdiutil} */
  const hdiutil = args => {
    if (args[0] === 'attach') attached.push(args.at(-1) ?? '')
    return execFileSync('/usr/bin/hdiutil', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  }
  return { attached, hdiutil }
}
