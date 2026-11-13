# Configuration

Open **Options → Settings…** to edit the configuration, with sections for **Collection**, **Display**, **Providers**, **Labels**, **Metrics**, **Runtime** and **Updates**. Edits are staged: **Save & Apply** validates everything, writes the file privately and atomically, saves any changed compact-view preferences, then, only when the collector configuration changed, restarts collection in place. **Cancel** or closing the window discards all staged edits. If the config save fails, nothing else is applied and your draft stays open. Changing the profile clears the previous profile's displayed data; compact preferences are scoped per configuration path and omp profile. API keys and authentication are not edited here; they stay managed by omp.

The file is `~/Library/Application Support/omp-usage-panel/config.json`; editing it by hand needs an app restart (see [usage](usage.md)). Do not put API keys in it.

| Field | Default | Meaning |
| --- | --- | --- |
| `ompPath` | discovered at install | Absolute path of the omp executable |
| `profile` | `default` | omp profile that holds authentication |
| `refreshSeconds` | `60` | Collector interval |
| `cacheMinutes` | `5` | Usage cache lifetime; `0` queries every time |
| `timeoutSeconds` | `25` | omp subprocess timeout |
| `providers` | `null` | `null` shows all; an array selects and orders the summary cards only. Hidden providers stay reachable through **Providers → All**/provider |
| `labels` | `{}` | Provider ID → display name |
| `metrics` | `{}` | Provider ID → limit ID shown as its representative metric |
| `warnPercent` / `criticalPercent` | `70` / `90` | Thresholds |
| `showPace` | `true` | Show the elapsed-period marker |

`nodePath` is a legacy field that must still be an absolute path, but it is not edited in Settings and the app never runs it: collection, setup and updates always use the bundled Node.js. Its directory is still placed first on the `PATH` given to omp, so an omp wrapper that runs `env node` resolves the Node.js it points at (installs point it at the bundled runtime).

Metric limit IDs are at `snapshot.accounts[].limits[].id` in collector output. Choosing a metric changes only the display, not omp's account selection.

## Collector

The collector can run on its own from a checkout:

```sh
node packages/usage-core/cli.mjs            # JSON: snapshot, source, optional error
node packages/usage-core/cli.mjs --refresh  # runs `omp usage invalidate` first
```

`source` is `live`, `cache`, `stale`, or `unavailable`. Schema: [types.ts](../packages/usage-core/types.ts). A failed refresh keeps the last good snapshot, marked `stale`; zero usage is never invented. Cache files can contain account identifiers, so do not commit them. Cache root: `OMP_USAGE_CACHE_DIR`.
