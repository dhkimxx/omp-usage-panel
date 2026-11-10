import { install } from './installation.mjs'

if (import.meta.main) {
  const args = process.argv.slice(2)
  if (args.includes('--help')) {
    console.log('Usage: node install.mjs [--dry-run]\nUses OMP_BIN and OMP_PROFILE when creating the initial configuration.')
  } else if (args.some(arg => arg !== '--dry-run') || args.filter(arg => arg === '--dry-run').length > 1) {
    console.error('Usage: node install.mjs [--dry-run]')
    process.exitCode = 1
  } else {
    try { console.log(install({ dryRun: args.includes('--dry-run') }).join('\n')) }
    catch (error) { console.error(`Install failed: ${error instanceof Error ? error.message : String(error)}`); process.exitCode = 1 }
  }
}
