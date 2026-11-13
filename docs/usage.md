# Using OMP Usage

## The panel

- On a notched screen, compact provider rings sit on either side of the camera, as chosen per provider. Otherwise a single capsule floats below the menu bar.
- Hover anywhere on the compact panel to preview the overview. Click a ring, or a provider card in the overview, for that provider's details. The **Providers** dropdown in the overview header chooses **All** or one provider; the detail view has the same filter at the start of its account row, with **Overview** to go back. **More** opens the overview. **Escape** or an outside click collapses it.
- **All** and the provider list come from the full collected catalog, including providers hidden from the summary cards or currently unavailable. These selections only change what is displayed and never change credentials.
- The **Providers** and **Account** pickers are keyboard-friendly lists (**↑/↓**, **Home/End**, **Return/Space**); **Escape** or an outside click closes only the list.
- **Options** (or right-click): Settings…, refresh, open data folder, reset position, quit.
- **Option-drag** moves the panel; **Reset position** restores automatic placement on the configured monitor (it does not change the monitor choice).
- The summary is the highest single observed utilization, not an account total. Unknown values are not zero.

**Quit** does not immediately restart the app. To reopen it, or to apply manual edits made to `config.json` outside the app:

```sh
launchctl kickstart -k "gui/$(id -u)/com.dhkim.omp-usage-panel"
```

## Compact view

Open **Settings → Display → Compact view** to choose which providers appear, set each provider's **Left** or **Right** side of the camera, and set one **Maximum slots** total (default `3`). Changes are staged and apply on **Save & Apply**.

- Selection is independent of the slot cap. The maximum is shared across both wings and includes the single aggregate **More** control: five selected providers with three slots show two rings and **+3**. **More** lists every hidden provider, including ones assigned to the other side.
- A provider is never moved to the opposite side to fit. Each wing is also limited by the physical space beside the camera.
- These choices affect only the compact display, not collection, authentication or the expanded dashboard.
- Preferences are saved per configuration path and omp profile and survive restarts and reinstallation. Clearing every provider leaves a **+** button that opens Settings → Display.
- Once a successful usage result no longer reports a provider, its ring and open provider detail disappear. Its saved selection and side are kept for reconnection; later failed or stale refreshes do not undo a confirmed removal.
- Removal follows collection timing: normal polling defaults to 60 seconds and may serve the five-minute usage cache. **Refresh** bypasses that cache. The panel does not watch or edit omp credentials.
- Without a notch (or when the panel is moved), rings form one contiguous capsule below the menu bar, left group then right group, with no camera gap.
- Screen bounds may reduce the effective cap. App and status-menu occupancy is not detected; reduce the count or change sides if menus overlap.

## Panel placement (monitor)

Open **Settings → Display → Panel placement** and use the **Monitor** dropdown:

- **System primary (Default)** keeps the panel on the display macOS marks as primary (the one with the menu bar). It does not follow the pointer, the active window or keyboard focus. If you change the primary display in macOS, the panel follows that change.
- A named monitor pins the panel to that physical display, even when it is not the primary one. Monitors are remembered by display UUID; choosing the primary display explicitly differs from the default because it keeps that monitor if the primary changes.
- If the pinned monitor is disconnected, it stays listed as **Disconnected monitor** and your choice is kept. The panel temporarily uses the System primary display and moves back when that monitor reconnects.
- A position you set with **Option-drag** overrides the configured monitor. **Reset position** clears only that override; saving a different monitor in Settings also clears it.
- The choice is app-wide (not per omp profile), staged until **Save & Apply**. macOS display settings are never changed.

## Updates

The app checks GitHub for new versions. Updates are prebuilt universal (arm64 + x86_64) apps; no Xcode or source build is needed, and they are fetched by the app itself, so they are never quarantined.

- **Defaults:** daily checks on, notifications on, automatic installation **off**.
- **Settings → Updates** (app-wide, not per omp profile) holds these controls. **Check for Updates…** in the menu runs a manual check, which ignores Skip and turned-off notifications.
- **Popup:** a new version shows a prompt with **Update Now** (this version only), **Skip This Version**, **Later** (asks again after 24 hours) and **Turn Off Notifications**. Installing automatically is a separate, optional consent; notifications, Skip and Later never grant it. Automatic installation only restarts the app while it is idle.
- **Verification:** the update feed and archive are Ed25519-signed and verified by Sparkle before installation. After Sparkle replaces the app, a watcher checks the installed file tree against the authenticated hash before the new app starts; a wrong hash rolls back. The updater keeps a copy of its watcher and a backup outside the app bundle, restarts the original LaunchAgent, waits for the new app's startup acknowledgment and rolls back if it does not report healthy. Your config, auth and provider plugins are preserved.
- **Signing:** no Apple Developer ID is used. The app is ad-hoc signed and not notarized, and the Ed25519 update signature is not Apple code signing or notarization.
