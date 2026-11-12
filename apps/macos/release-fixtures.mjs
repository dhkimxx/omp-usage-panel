import { sign as cryptoSign } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { dmgAppName } from './dmg.mjs'

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

/** Universal (arm64 + x86_64), ad-hoc deep-signed app. @param {string} directory @param {{version?: string, universal?: boolean}} [options] */
export function buildFixtureApp(directory, { version = '1.0.0', universal = true } = {}) {
  const root = path.join(directory, `app-${version}-${universal}`), app = path.join(root, dmgAppName)
  mkdirSync(path.join(app, 'Contents/MacOS'), { recursive: true })
  writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>OMPUsagePanel</string><key>CFBundleIdentifier</key><string>com.example.omp-usage-fixture</string><key>CFBundleName</key><string>OMP Usage</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>${version}</string></dict></plist>\n`)
  const source = path.join(root, 'main.c')
  writeFileSync(source, 'int main(void) { return 0; }\n')
  execFileSync('/usr/bin/xcrun', ['clang', ...(universal ? ['-arch', 'arm64', '-arch', 'x86_64'] : ['-arch', process.arch === 'arm64' ? 'arm64' : 'x86_64']), '-o', path.join(app, 'Contents/MacOS/OMPUsagePanel'), source], { stdio: 'pipe' })
  rmSync(source)
  mkdirSync(path.join(app, 'Contents/Resources')); writeFileSync(path.join(app, 'Contents/Resources/data.txt'), 'resource')
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
