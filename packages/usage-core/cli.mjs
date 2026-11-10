#!/usr/bin/env node
import { collectUsage, collectorOptionsFromEnv } from './index.mjs';

const args = process.argv.slice(2);
if (args.some(arg => arg !== '--refresh')) {
  console.error('Usage: node cli.mjs [--refresh]');
  process.exitCode = 2;
} else {
  const result = await collectUsage({ ...collectorOptionsFromEnv(), force: args.includes('--refresh') });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
