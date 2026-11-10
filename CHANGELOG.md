# Changelog

## 0.1.0

- Extract the common usage collector and complete macOS AppKit dashboard from `my-omp-patch`; keep provider API/authentication patches in their own repository.
- Remove provider packaging and plugin management from dashboard installation/removal. Preserve existing application identity, configuration, cache, saved placement and legacy ownership records during migration.
- Provide source-independent app installation, login startup, ownership verification and transactional rollback; distribute through the source installer rather than an unsupported standalone binary.
- Integrate the black dashboard directly with the physical notch: screen-top expanded board, camera-safe header and a camera-width compact silhouette with thin provider status lines. Keep floating/no-notch placement below the menu bar and support Option-drag/reset.
- Align provider-card content with consistent 12pt padding; retain exact account/limit selection, explicit estimated resets, unknown/error states, all-account details and reduced-motion-aware transitions.
- Keep the Node-only collector, per-profile cache/stale recovery and JSON schema reusable independently of AppKit. Mark Ubuntu and Windows frontends explicitly TODO.
- Retain behavioral coverage for collector boundaries, application ownership/rollback and native model/layout/transition invariants; add macOS/Ubuntu verification and a complete macOS app build in CI.
