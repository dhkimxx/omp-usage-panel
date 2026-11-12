# Changelog

## 0.2.1

- Keep the usage panel on one stable monitor: the default **System primary** display no longer depends on which monitor has focus, so multi-monitor setups stop jumping between displays. **Settings → Display → Panel placement → Monitor** can instead pin a connected physical monitor (identified by its display UUID, not a transient ID). A pinned monitor that is unplugged is shown as unavailable, the panel temporarily uses the System primary display, and it returns when the monitor reconnects. Saving a different monitor resets a manual position; **Reset position** keeps the chosen monitor. The choice is app-wide, staged with **Save & Apply** / **Cancel**, and never changes macOS display settings. Older versions ignore the new preference and use their own placement.

## 0.2.0

- Add GitHub updates through pinned Sparkle 2.10.1: daily checks and notifications on, automatic installation off by default, a native Update Now / Skip This Version / Later / Turn Off Notifications prompt, optional automatic-install consent, manual **Check for Updates…** and an app-wide **Updates** settings tab with Save & Apply / Cancel. Automatic restarts wait until the app is idle.
- Authenticate the feed and archive with Ed25519 and a signed app-tree hash; restart the original LaunchAgent from an out-of-bundle watcher, require native startup acknowledgment and roll back on failed health, preserving config, auth and provider plugins.
- Source install is now a one-time bootstrap; later updates are prebuilt universal (arm64 + x86_64) apps. Updates remain ad-hoc signed and not notarized.
- Add maintainer `release:setup` (initial channel establishment only), `release:package` and `release:publish --notes-file <file> [--dry-run]` flow with the root `package.json` version as authority and the signing key held only in the local Keychain.

- Replace **Open config** with a native **Settings…** window that edits every user-editable configuration field (collection, display, providers, labels, metrics, runtime) with **Save & Apply** and **Cancel**; authentication remains managed by omp.
- Persist Settings saves by validating the complete configuration and atomically replacing the private config file, leaving the file and running configuration unchanged on failure.
- Apply saved settings live by replacing the collector and refresh timer in place, ignoring stale results from earlier generations, and resetting old profile data and details when the profile changes.
- Unify Settings into one cohesive dark custom-styled window with a sidebar; compact provider selection, maximum and Left/Right placement live in **Display → Compact view**. Remove the separate **Compact settings…** window and autosave: compact edits are staged, scoped per configuration path and profile, and applied with **Save & Apply** or discarded with **Cancel**. Configure/**+** opens Display directly.
- Replace compact hairlines with provider-mark donut rings on either side of the camera and a single floating capsule. Add persistent, configuration/profile-scoped provider selection, a shared total maximum that includes one aggregate **More** control, and per-provider Left/Right placement (older single-side preferences migrate) without filtering expanded data. With no notch, rings form one contiguous capsule with no camera gap.
- Open hover previews across the entire compact panel, including the camera, rings, padding and floating mode. Require a genuine exit before reopening after explicit dismissal.
- Distinguish unknown, known-zero and over-limit rings, retaining exact usage and collection warnings even for saved providers missing from the current report.
- Round both exposed compact lower corners and preserve the grabbed ring's position when detaching from the notch into a floating row.
- Support standard native settings text-editing shortcuts under non-Latin input methods.
- Replace separate account popovers with inline provider/all-account details, a fixed account selector and independent usage/metadata scrolling. Keep selection display-only and retain original IDs, limits, notes and unavailable reports.
- Make metric cards denser and content-sized (shared heading/timing, smaller primary value, thin progress, inline footer and Details disclosure) without clipping values or hiding scrolling; preserve zero, unknown, remaining-only balances, over-limit usage, explicitly estimated periods and all original metadata.
- Add pinned detail navigation, keyboard focus/Escape handling and passive outside-click dismissal without immediate hover reopening.
- Reconcile animation geometry with AppKit's realized window/content bounds instead of requested fractional sizes, preventing an unfilled top strip during resize.
- Align overview/detail actions with shared text, symbol, padding and camera-fit measurements; center icon-only controls and reserve a trailing picker chevron.
- Consolidate account information into one unfolded, content-sized card. Omit missing plan/fetch fields and raw account metadata, keep useful notes/cautions, and distinguish retained snapshots after refresh failures.
- Unify provider navigation behind one shared Providers filter (**All**/provider) in the overview header and detail account row, backed by the full collected catalog including summary-hidden and unavailable providers. Remove the standalone Accounts button, the **All accounts** menu entry and the detail scope-chip strip.
- Center provider titles on overview cards and the provider filter's title, with stable warning-space reservation so titles do not shift; numeric and body alignment are unchanged.
- Fix a ring going missing after moving a provider directly from the right wing to the left: compact rows now reconcile the actual view hierarchy in two phases, removing old children from both wings before re-adding, and repair already orphaned rings without resetting preferences.
- Replace the native provider/account menus with a custom scrollable dropdown list (provider mark, title, subtitle, selected check, disabled/unavailable rows) with keyboard navigation, Escape-closes-list-only, outside-click dismissal and toggle on reopening; it holds tracking for its whole lifetime and releases once.
- Replace the native combo-box suggestion lists for Settings Providers/Labels/Metrics IDs with the same custom list on native editable text fields, preserving arbitrary IDs, IME composition, selection, undo and clipboard shortcuts, with no unsolicited completion. OS file dialogs and Options/context menus stay native.
- Preserve saved compact preferences forward and keep them readable by an automatic rollback to the previous version: selected providers, total maximum and a default side are still persisted in the older format, while per-provider Left/Right overrides are retained as additional data. An older UI cannot render mixed per-provider wings and falls back to the default side; it does not drop the saved membership or maximum.

## 0.1.0

- Extract the common usage collector and complete macOS AppKit dashboard from the previous repository; keep provider API/authentication patches in their own repository.
- Remove provider packaging and plugin management from dashboard installation/removal. Preserve existing application identity, configuration, cache, saved placement and legacy ownership records during migration.
- Provide source-independent app installation, login startup, ownership verification and transactional rollback; distribute through the source installer rather than an unsupported standalone binary.
- Integrate the black dashboard directly with the physical notch: screen-top expanded board, camera-safe header and a camera-width compact silhouette with thin provider status lines. Keep floating/no-notch placement below the menu bar and support Option-drag/reset.
- Align provider-card content with consistent 12pt padding; retain exact account/limit selection, explicit estimated resets, unknown/error states, all-account details and reduced-motion-aware transitions.
- Keep the Node-only collector, per-profile cache/stale recovery and JSON schema reusable independently of AppKit.
- Retain behavioral coverage for collector boundaries, application ownership/rollback and native model/layout/transition invariants; add macOS verification and a complete macOS app build in CI.
