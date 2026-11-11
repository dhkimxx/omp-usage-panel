# Changelog

## Unreleased

- Replace **Open config** with a native **Settings…** window that edits every user-editable configuration field (collection, display, providers, labels, metrics, runtime) with **Save & Apply** and **Cancel**; authentication remains managed by omp.
- Persist Settings saves by validating the complete configuration and atomically replacing the private config file, leaving the file and running configuration unchanged on failure.
- Apply saved settings live by replacing the collector and refresh timer in place, ignoring stale results from earlier generations, and resetting old profile data and details when the profile changes.
- Replace compact hairlines with provider-mark donut rings beside the camera and a floating ring capsule. Add persistent, configuration/profile-scoped provider selection, total slot limits including More, and left/right placement without filtering expanded data.
- Open hover previews across the entire compact panel, including the camera, rings, padding and floating mode. Require a genuine exit before reopening after explicit dismissal.
- Distinguish unknown, known-zero and over-limit rings, retaining exact usage and collection warnings even for saved providers missing from the current report.
- Round both exposed compact lower corners and preserve the grabbed ring's position when detaching an asymmetric notch wing.
- Support standard native settings text-editing shortcuts under non-Latin input methods.
- Replace separate account popovers with inline provider/all-account details, a fixed account selector and independent usage/metadata scrolling. Keep selection display-only and retain original IDs, limits, notes and unavailable reports.
- Keep metric cards compact, with raw metadata available through Details disclosures; preserve zero, unknown, remaining-only balances, over-limit usage and explicitly estimated periods.
- Add pinned detail navigation, keyboard focus/Escape handling and passive outside-click dismissal without immediate hover reopening.
- Reconcile animation geometry with AppKit's realized window/content bounds instead of requested fractional sizes, preventing an unfilled top strip during resize.
- Align overview/detail actions with shared text, symbol, padding and camera-fit measurements; center icon-only controls and reserve a trailing picker chevron.
- Consolidate account information into one unfolded, content-sized card. Omit missing plan/fetch fields and raw account metadata, keep useful notes/cautions, and distinguish retained snapshots after refresh failures.
- Unify provider navigation behind one shared Providers filter (**All**/provider) in the overview header and detail account row, backed by the full collected catalog including summary-hidden and unavailable providers. Remove the standalone Accounts button, the **All accounts** menu entry and the detail scope-chip strip.
- Center provider titles on overview cards and the provider filter's title, with stable warning-space reservation so titles do not shift; numeric and body alignment are unchanged.

## 0.1.0

- Extract the common usage collector and complete macOS AppKit dashboard from the previous repository; keep provider API/authentication patches in their own repository.
- Remove provider packaging and plugin management from dashboard installation/removal. Preserve existing application identity, configuration, cache, saved placement and legacy ownership records during migration.
- Provide source-independent app installation, login startup, ownership verification and transactional rollback; distribute through the source installer rather than an unsupported standalone binary.
- Integrate the black dashboard directly with the physical notch: screen-top expanded board, camera-safe header and a camera-width compact silhouette with thin provider status lines. Keep floating/no-notch placement below the menu bar and support Option-drag/reset.
- Align provider-card content with consistent 12pt padding; retain exact account/limit selection, explicit estimated resets, unknown/error states, all-account details and reduced-motion-aware transitions.
- Keep the Node-only collector, per-profile cache/stale recovery and JSON schema reusable independently of AppKit.
- Retain behavioral coverage for collector boundaries, application ownership/rollback and native model/layout/transition invariants; add macOS verification and a complete macOS app build in CI.
