import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
export const channelPath = path.join(sourceRoot, 'apps/macos/update-channel.json')
export const feedPath = path.join(sourceRoot, 'updates/appcast.xml')
export const sparkle = Object.freeze({
  version: '2.10.1',
  url: 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz',
  size: 16346336,
  sha256: '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27',
})
export const defaults = Object.freeze({
  repository: 'dhkimxx/omp-usage-panel',
  feedURL: 'https://raw.githubusercontent.com/dhkimxx/omp-usage-panel/main/updates/appcast.xml',
  account: 'dhkimxx.omp-usage-panel',
  namespace: 'https://github.com/dhkimxx/omp-usage-panel/updates',
  minimumSystemVersion: '13.0',
})

export function rootVersion() {
  const { version } = JSON.parse(readFileSync(path.join(sourceRoot, 'package.json'), 'utf8'))
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`Root package.json version must be MAJOR.MINOR.PATCH, got ${JSON.stringify(version)}`)
  return version
}

/** @param {string} file */
function sha256File(file) { return createHash('sha256').update(readFileSync(file)).digest('hex') }

export function sparkleCacheRoot() {
  return path.resolve(process.env.OMP_USAGE_SPARKLE_CACHE || path.join(homedir(), 'Library/Caches/omp-usage-panel/sparkle', sparkle.version))
}

/** @typedef {{root: string, framework: string, license: string, signUpdate: string, generateKeys: string}} SparkleSdk */
/**
 * Download (if needed) and verify the pinned Sparkle archive, then extract it only after the digest matches.
 * @returns {SparkleSdk}
 */
export function ensureSparkleSdk() {
  const cache = sparkleCacheRoot(), archive = path.join(cache, `Sparkle-${sparkle.version}.tar.xz`), root = path.join(cache, 'sdk'), marker = path.join(cache, 'sdk.sha256')
  mkdirSync(cache, { recursive: true })
  /** @param {string} file */
  const verified = file => existsSync(file) && statSync(file).size === sparkle.size && sha256File(file) === sparkle.sha256
  if (!verified(archive)) {
    rmSync(archive, { force: true })
    const temp = `${archive}.partial`
    rmSync(temp, { force: true })
    try {
      execFileSync('/usr/bin/curl', ['--fail', '--location', '--proto', '=https', '--silent', '--show-error', '--output', temp, sparkle.url], { stdio: 'inherit' })
      if (!verified(temp)) throw new Error('Downloaded Sparkle archive does not match the pinned size/SHA-256')
      renameSync(temp, archive)
    } finally { rmSync(temp, { force: true }) }
  }
  const sdkReady = existsSync(path.join(root, 'Sparkle.framework/Versions/B/Sparkle')) && existsSync(marker) && readFileSync(marker, 'utf8').trim() === sparkle.sha256
  if (!sdkReady) {
    const stage = mkdtempSync(path.join(cache, '.extract-'))
    try {
      execFileSync('/usr/bin/tar', ['-xJf', archive, '-C', stage], { stdio: 'inherit' })
      for (const required of ['Sparkle.framework', 'bin/sign_update', 'bin/generate_keys', 'LICENSE']) if (!existsSync(path.join(stage, required))) throw new Error(`Sparkle archive is missing ${required}`)
      rmSync(root, { recursive: true, force: true })
      renameSync(stage, root)
      writeFileSync(marker, `${sparkle.sha256}\n`)
    } finally { rmSync(stage, { recursive: true, force: true }) }
  }
  return { root, framework: path.join(root, 'Sparkle.framework'), license: path.join(root, 'LICENSE'), signUpdate: path.join(root, 'bin/sign_update'), generateKeys: path.join(root, 'bin/generate_keys') }
}

/**
 * Validates the bytes of update-channel.json against the project update channel. Pure: callers decide where the bytes come from.
 * @param {string|Uint8Array} data @returns {{feedURL:string, publicEDKey:string, account:string, namespace:string}}
 */
export function parseChannel(data) {
  const value = JSON.parse(typeof data === 'string' ? data : Buffer.from(data).toString('utf8'))
  if (value.feedURL !== defaults.feedURL || value.account !== defaults.account || value.namespace !== defaults.namespace) throw new Error('update-channel.json does not match the project update channel')
  if (typeof value.publicEDKey !== 'string' || Buffer.from(value.publicEDKey, 'base64').length !== 32 || Buffer.from(value.publicEDKey, 'base64').toString('base64') !== value.publicEDKey) throw new Error('update-channel.json publicEDKey is not a valid Ed25519 public key')
  return { feedURL: value.feedURL, publicEDKey: value.publicEDKey, account: value.account, namespace: value.namespace }
}

/** @returns {{feedURL:string, publicEDKey:string, account:string, namespace:string}} */
export function readChannel() {
  if (!existsSync(channelPath)) throw new Error('apps/macos/update-channel.json is missing; run `npm run release:setup` first')
  return parseChannel(readFileSync(channelPath, 'utf8'))
}
