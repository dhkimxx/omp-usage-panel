# External usage snapshot contract (version 1)

The macOS bridge reads opt-in `externalSources` from [configuration](configuration.md). This interface is file I/O only: the panel never launches a producer, evaluates a shell command, reads provider credentials or calls a provider API. Install and authorize a producer separately. A source owns its configured provider ID and replaces every OMP account and unavailable report for that ID, including on errors.

## Envelope

```json
{
  "version": 1,
  "providerId": "google-antigravity",
  "snapshot": {
    "version": 1,
    "capturedAt": 1794873600000,
    "accounts": [{
      "id": "antigravity-cli",
      "provider": "google-antigravity",
      "label": "Antigravity CLI",
      "fetchedAt": 1794873600000,
      "notes": [],
      "limits": [{
        "id": "quota-bucket/5h",
        "label": "5 hours",
        "amount": { "unit": "percent", "used": 25, "limit": 100, "remaining": 75 },
        "usedFraction": 0.25,
        "window": { "id": "5h", "label": "5 hours", "durationMs": 18000000, "resetsAt": 1794891600000 },
        "notes": []
      }]
    }],
    "unavailable": []
  }
}
```

The example is synthetic, not evidence of collected quota. Envelope keys are exactly `version`, `providerId`, `snapshot`, and optional `errorCode`. `providerId` must equal the configured ID, with exact string identity. `snapshot` is either a normalized `UsageSnapshot` or explicit `null`. Every account **and** unavailable report must belong to the configured provider; a mixed-provider snapshot is rejected as a whole. Files must contain one valid JSON document, be at most **1 MiB (1,048,576 bytes)** and be regular files, not symlinks, FIFOs or devices. The consumer checks the opened file's size before reading it.

`errorCode`, when present, is one of:

- `CLI_NOT_FOUND`
- `AUTH_REQUIRED`
- `COLLECT_FAILED`
- `INVALID_OUTPUT`
- `NO_QUOTA`
- `UNSAFE_CONFIG`

Do not put raw errors, CLI output, email addresses, account identifiers, tokens or credentials in `errorCode`, labels, IDs or notes. Producer IDs should be stable non-PII identifiers. The panel validates structure and ownership, not the truth or sensitivity of arbitrary strings: only configure a trusted local producer.

## Normalized snapshot fields

The consumer reuses the same `validUsageSnapshot` validator as the OMP disk cache, exported from [collector.mjs](../packages/usage-core/collector.mjs). Types are [types.ts](../packages/usage-core/types.ts); do not send raw CLI/provider response schemas.

| Object | Required | Optional (omit when absent; do not send `null`) |
| --- | --- | --- |
| Snapshot | `version: 1`, finite `capturedAt`, `accounts: []`, `unavailable: []` | — |
| Account | string `id`, `provider`, `label`; finite `fetchedAt`; `notes: string[]`; `limits: []` | string `plan` |
| Limit | string `id`, `label`; `amount`; `notes: string[]` | finite `usedFraction`; string `status`; `window` |
| Amount | string `unit` | finite `used`, `limit`, `remaining` |
| Window | string `id`, `label` | finite `durationMs`, `resetsAt`; string `resetLabel`; boolean `estimated` |
| Unavailable | string `provider`, `label`, `reason` | — |

All timestamps are **epoch milliseconds**; durations are milliseconds. Notes arrays are required even when empty. Multiple quota buckets/windows remain distinct limits with stable IDs; the summary selects the highest single utilization, not a sum. `usedFraction` is used / limit, not a percent. For remaining fraction `r`, export `usedFraction = 1-r`, percent amount `used = 100*(1-r)`, `limit = 100`, `remaining = 100*r`. Do not invent quota or credit limits when the official source supplies none.

## Publishing and freshness

- Default Antigravity producer location: `~/Library/Application Support/omp-antigravity-usage-plugin/snapshot.json`. Configure its expanded absolute path in the panel.
- Producer directory permissions: `0700`; file permissions: `0600`. Create a private temporary file in that directory, finish writing it, then atomically rename it over `snapshot.json`. Do not publish partial JSON or replace it with a symlink. The panel never writes or repairs producer files.
- A successful capture uses the actual observation time for `capturedAt` and appropriate account `fetchedAt`; it removes a previous `errorCode`. For the passive Antigravity statusline source, these are callback observation times: the callback carries no independent backend-fetch timestamp. State that limitation in account notes.
- On failure, retain the **exact last successful snapshot and its timestamps**, adding only a fixed `errorCode`. With no last successful snapshot, publish `snapshot: null` plus the code. Empty/no-quota observations must not be published as a successful zero: use `NO_QUOTA`.
- Freshness is checked independently for each configured file. `capturedAt` and every account's `fetchedAt` must be nonnegative, not in the future and strictly younger than `cacheMinutes * 60000`. At the boundary they are expired; `cacheMinutes: 0` always expires external data. File mtime, a new OMP result, or rereading an unchanged file cannot renew it. An error code marks retained quota stale even within the age window.
- Refresh reads existing files only. In particular, the passive Antigravity statusline exporter receives observations when the official CLI invokes it. An idle CLI yields stale data over time; the panel never automatically sends `/usage` or a model prompt. The active CLI account is independent of the panel's OMP profile.

## Consumer result

With no configured sources the existing bridge behavior and JSON shape are unchanged. With sources enabled, collection still returns `snapshot`, `source`, optional `error`, and `summaries`; it additionally returns `providerSources`, an array of `{provider, source, capturedAt, error?}`, and bridge-only `ompSource: {source, capturedAt, providers, error?}` provenance. This does not change the producer's version-1 envelope. Each entry uses the original source capture (or `null` if none), not the merge time. `ompSource` retains the independent OMP clock and roster even when OMP successfully reports no providers. OMP provider entries retain the OMP collector's source and error; external successes use `cache` because they are file observations, never direct live fetches.

| External observation | Provider source | Quota display |
| --- | --- | --- |
| Valid, fresh, displayable quota without unavailable reports | `cache` | Supplied quota |
| Expired/future-dated or producer error with displayable quota | `stale` | Retained quota with explicit warning |
| Fresh quota plus any unavailable report | `stale` | Supplied quota remains visible, with `NO_QUOTA` (or the producer code) warning; never presented as wholly healthy |
| Missing/oversized/non-JSON/bad envelope/wrong provider/null snapshot | `unavailable` | Unknown (`—`), not zero; null captures never borrow another source's time |
| Empty, unavailable-only, limitless accounts or limits without displayable quota | `unavailable` | Unknown; `NO_QUOTA` when no producer code is supplied |

Consumer read/parse failures expose only fixed messages such as `External snapshot unavailable` or `INVALID_OUTPUT`, never a file path or raw payload. Producer codes remain fixed allowlisted strings.

Displayable quota means at least one limit has a nonnegative `usedFraction` that produces a finite percentage, or an explicit `status: "exhausted"`. Amount-only metadata is not converted into invented utilization. A fresh account without such a limit is not a healthy quota observation. A mixed quota/unavailable observation is deliberately conservative: its known quota is retained, but the whole provider is marked degraded.

Aggregate `source` is `partial` if healthy and failed sources coexist, `stale` if only retained quota remains, and `unavailable` if no source has usable data; without failures the OMP collector's `live`/`cache` source is retained. A valid empty OMP result remains a successful collection. If no source has an actual usable capture, `snapshot` is **null**, preserving the native last-good guard; no epoch-zero timestamp is synthesized. Otherwise the merged `capturedAt` is the oldest included capture, a conservative aggregate only.

The native intake compares OMP captures against accepted OMP data, independently of external clocks. An old OMP cache cannot overwrite newer OMP quota or revive a removed provider, while a new external observation still advances. External clocks also survive unavailable observations, preventing older files from rolling back the latest seen state. The producer owns last-good external payload retention.

Roster confirmation is source-local, not gated by the aggregate `source` or error. An accepted healthy OMP group (`live` or `cache`, no OMP error, with its own capture) confirms OMP additions and removals using the OMP clock, even when an external file makes the overall result `partial`. A successful empty OMP roster confirms removal of all OMP providers. Configured external provider IDs remain members regardless of file health, preserving their selected unavailable slots and never restoring OMP data for those IDs. Failed/stale OMP data or an older OMP group cannot change OMP membership or advance `confirmedAt`, even alongside fresh external quota. Before any healthy OMP confirmation, the roster remains unknown and saved compact placeholders and detail scopes remain intact; an OMP failure plus healthy external data cannot confirm an external-only roster.

An OMP failure cannot suppress healthy external quota. A failed external file cannot suppress other providers or restore duplicate OMP data for its owned ID. Provider warning flags and detail freshness are source-local; the overall header describes partial failure, while transport errors and active refresh status remain visible in every provider tooltip.
