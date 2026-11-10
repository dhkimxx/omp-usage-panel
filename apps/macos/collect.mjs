import path from 'node:path'
import { readFile } from 'node:fs/promises'
import { collectUsage } from '../../packages/usage-core/collector.mjs'
import { summarizeProviders } from '../../packages/usage-core/summary.mjs'
import { parseConfig } from './config.mjs'

/** @param {string[]} args */
export async function collect(args) {
  if ((args.length !== 2 && args.length !== 3) || args[0] !== '--config' || !args[1] || !path.isAbsolute(args[1]) || (args.length === 3 && args[2] !== '--refresh')) throw new Error('Invalid arguments')
  const config = parseConfig(JSON.parse(await readFile(args[1], 'utf8')))
  const result = await collectUsage({ ompBin: config.ompPath, profile: config.profile, maxAgeMs: config.cacheMinutes * 60000, timeoutMs: config.timeoutSeconds * 1000, force: args.length === 3 })
  return { ...result, summaries: summarizeProviders(result, config) }
}

if (import.meta.main) {
  try { process.stdout.write(`${JSON.stringify(await collect(process.argv.slice(2)))}\n`) }
  catch { process.stderr.write('Unable to read configuration or collect usage\n'); process.exitCode = 1 }
}
