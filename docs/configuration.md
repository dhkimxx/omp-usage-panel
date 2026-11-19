# Configuration

Open **Options → Settings…** to edit the configuration, with sections for **Collection**, **Display**, **Providers**, **Labels**, **Metrics**, **Runtime** and **Updates**. Edits are staged: **Save & Apply** validates everything, writes the file privately and atomically, saves any changed compact-view preferences, then, only when the collector configuration changed, restarts collection in place. **Cancel** or closing the window discards all staged edits. If the config save fails, nothing else is applied and your draft stays open. Changing the profile clears the previous profile's displayed data; compact preferences are scoped per configuration path and omp profile. API keys and authentication are not edited here; they stay managed by omp.

The file is `~/Library/Application Support/omp-usage-panel/config.json`; editing it by hand needs an app restart (see [usage](usage.md)). Do not put API keys in it.

| Field | Default | Meaning |
| --- | --- | --- |
| `ompPath` | discovered at install | Absolute path of the omp executable |
| `profile` | `default` | omp profile that holds authentication |
| `refreshSeconds` | `60` | Collector interval |
| `cacheMinutes` | `5` | OMP cache lifetime and external snapshot maximum age; `0` queries OMP every time and marks every external snapshot expired |
| `timeoutSeconds` | `25` | omp subprocess timeout |
| `providers` | `null` | `null` shows all; an array selects and orders the summary cards only. Hidden providers stay reachable through **Providers → All**/provider |
| `labels` | `{}` | Provider ID → display name |
| `metrics` | `{}` | Provider ID → limit ID shown as its representative metric |
| `warnPercent` / `criticalPercent` | `70` / `90` | Thresholds |
| `showPace` | `true` | Show the elapsed-period marker |
| `externalSources` | `[]` | Optional file-only providers: `[{ "providerId": "...", "path": "/absolute/snapshot.json" }]`; missing in legacy files means `[]` |

`nodePath` is a legacy field that must still be an absolute path, but it is not edited in Settings and the app never runs it: collection, setup and updates always use the bundled Node.js. Its directory is still placed first on the `PATH` given to omp, so an omp wrapper that runs `env node` resolves the Node.js it points at (installs point it at the bundled runtime).

Metric limit IDs are at `snapshot.accounts[].limits[].id` in collector output. Choosing a metric changes only the display, not omp's account selection.

## External snapshot files (opt-in)

Add an `externalSources` array to the existing configuration, retaining its other fields. For example, on a Mac whose home directory is `/Users/example`:

```json
"externalSources": [
  {
    "providerId": "google-antigravity",
    "path": "/Users/example/Library/Application Support/omp-antigravity-usage-plugin/snapshot.json"
  }
]
```

Use your actual **absolute** path: `~`, environment variables and shell expressions are not expanded. Each entry has exactly `providerId` and `path`; blank or duplicate provider IDs, extra keys and relative paths are rejected. This is a configuration-file option, not a Settings editor. For manual edits, **quit the app → back up and edit config → relaunch the app**. Do not use **Save & Apply** between editing and relaunching: native Settings still hold the old committed config and could overwrite your edits. After relaunch, **Save & Apply** preserves `externalSources` unchanged, including while changing profiles.

The panel only reads regular JSON files (not symlinks); it never runs a configured command, starts a plugin or reads that provider's credentials. Configure a separate, trusted producer using the [external snapshot wire contract](external-snapshots.md). Each configured source owns its provider ID: **all** OMP accounts and unavailable reports for that ID are replaced, even if the file is missing or invalid. Removing the entry disables the hook entirely and restores OMP's ownership. `providers` controls display selection, not source ownership.

Freshness uses each file's original `capturedAt` and each account's `fetchedAt`, never file modification time or merge time. Expired or future-dated captures and producer errors remain stale; absent/invalid files show unavailable, not zero. An OMP failure does not discard a successful external result, and an external failure does not discard OMP data. Mixed results report `partial`; provider-specific statuses, original capture times and fixed errors remain available in `providerSources`. Existing cards, compact rings and detail views are reused.

For Antigravity, the separate exporter uses the official **passive statusline callback**, not an automatic `/usage` prompt. Its default file is `~/Library/Application Support/omp-antigravity-usage-plugin/snapshot.json`. The active Antigravity CLI account is independent of the OMP profile. The panel does not install the exporter or request new quota; without CLI callbacks, the saved observation ages into stale data. Its capture time is the callback observation time, not proof of a fresh backend fetch. `Antigravity` / `AG` are presentation aliases only.

## Collector

The collector can run on its own from a checkout:

```sh
node packages/usage-core/cli.mjs            # JSON: snapshot, source, optional error
node packages/usage-core/cli.mjs --refresh  # runs `omp usage invalidate` first
```

`source` is `live`, `cache`, `stale`, or `unavailable`. Schema: [types.ts](../packages/usage-core/types.ts). A failed refresh keeps the last good snapshot, marked `stale`; zero usage is never invented. Cache files can contain account identifiers, so do not commit them. Cache root: `OMP_USAGE_CACHE_DIR`.

The macOS bridge includes configured external files before summarizing:

```sh
node apps/macos/collect.mjs --config "/absolute/path/to/config.json"
```

The core CLI above remains OMP-only. With `externalSources: []` (or a legacy config), the bridge keeps the existing collection behavior and output shape without source metadata.
