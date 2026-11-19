import Foundation
import CoreGraphics

private let builtInUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
private let dellUUID = "63FD4F17-3FBA-46CD-AD01-70F294053371"
private let builtIn = PlacementDisplay(uuid: builtInUUID, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isPrimary: true, name: "Built-in Retina Display", hasNotch: true)
private let dell = PlacementDisplay(uuid: dellUUID, frame: CGRect(x: -446, y: 1117, width: 1920, height: 1080), isPrimary: false, name: "DELL U2417H", hasNotch: false)

private func isolatedDefaults() -> (UserDefaults, () -> Void) { makeIsolatedDefaults(prefix: "omp-placement-tests") }

func runPanelPlacementTests() {
    let primary = PanelPlacementPreferences.defaults
    let explicitDell = PanelPlacementPreferences(displayUUID: dellUUID)

    // The primary display is the default whatever the inventory order is (focus is never an input).
    for displays in [[builtIn, dell], [dell, builtIn]] {
        let index = PanelPlacementResolver.targetIndex(primary, in: displays)!
        precondition(displays[index].uuid == builtInUUID)
    }
    // An explicit UUID wins over primary, is case-insensitive, and survives reordering.
    for displays in [[builtIn, dell], [dell, builtIn]] {
        precondition(displays[PanelPlacementResolver.targetIndex(explicitDell, in: displays)!].uuid == dellUUID)
        let lower = PanelPlacementPreferences(displayUUID: dellUUID.lowercased())
        precondition(displays[PanelPlacementResolver.targetIndex(lower, in: displays)!].uuid == dellUUID)
    }

    // Names never identify: two displays with the same name resolve by UUID, and the choices stay distinguishable.
    let twinA = PlacementDisplay(uuid: "AAAAAAAA-0000-0000-0000-000000000001", frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), isPrimary: false, name: "DELL U2417H", hasNotch: false)
    let twinB = PlacementDisplay(uuid: "AAAAAAAA-0000-0000-0000-000000000002", frame: CGRect(x: 3648, y: 0, width: 1920, height: 1080), isPrimary: false, name: "DELL U2417H", hasNotch: false)
    let twins = [builtIn, twinB, twinA]
    let pickB = PanelPlacementPreferences(displayUUID: twinB.uuid)
    precondition(twins[PanelPlacementResolver.targetIndex(pickB, in: twins)!] == twinB)
    let choices = PanelPlacementResolver.choices(twins)
    precondition(choices.map(\.uuid) == [builtInUUID, twinA.uuid!, twinB.uuid!])
    precondition(choices.filter(\.isPrimary).count == 1 && choices[0].isPrimary)
    precondition(choices.map(\.hasNotch) == [true, false, false], "Settings receives the same measured notch eligibility as placement")
    precondition(PanelPlacementResolver.choices([dell, builtIn]) == PanelPlacementResolver.choices([builtIn, dell]))

    // Disconnect: the target falls back to primary.
    let alone = [builtIn]
    precondition(PanelPlacementResolver.resolve(preferences: explicitDell, manual: nil, legacyPoint: nil, displays: alone)?.displayIndex == 0)
    // Reconnect, even with the displays renumbered into a different order: back on the configured display.
    precondition(PanelPlacementResolver.resolve(preferences: explicitDell, manual: nil, legacyPoint: nil, displays: [dell, builtIn])?.displayIndex == 0)

    // No inventory is deterministic: nothing resolves, nothing crashes.
    precondition(PanelPlacementResolver.targetIndex(primary, in: []) == nil)
    precondition(PanelPlacementResolver.resolve(preferences: explicitDell, manual: PanelManualPlacement(topCenter: .zero, anchor: nil), legacyPoint: nil, displays: []) == nil)
    precondition(PanelPlacementResolver.choices([]).isEmpty)
    // No display reports primary: the first one is the deterministic last resort.
    let noPrimary = [dell.withPrimary(false), builtIn.withPrimary(false)]
    precondition(PanelPlacementResolver.primaryIndex(in: noPrimary) == 0)

    // Manual placement: an anchored position follows its display, wherever the display has moved to.
    let anchor = PanelPlacementResolver.anchor(for: CGPoint(x: 100, y: 1500), on: dell)!
    precondition(anchor.displayUUID == dellUUID && anchor.offset == CGPoint(x: 546, y: 383))
    let manual = PanelManualPlacement(topCenter: CGPoint(x: 100, y: 1500), anchor: anchor)
    let moved = PlacementDisplay(uuid: dellUUID, frame: CGRect(x: 2000, y: -300, width: 1920, height: 1080), isPrimary: false, name: "DELL U2417H", hasNotch: false)
    let following = PanelPlacementResolver.resolve(preferences: primary, manual: manual, legacyPoint: nil, displays: [builtIn, moved])!
    precondition(following.displayIndex == 1 && following.manualTopCenter == CGPoint(x: 2546, y: 83))
    // Disconnected anchor: shown on the fallback at the same relative spot; the saved manual value is not touched.
    let fallback = PanelPlacementResolver.resolve(preferences: primary, manual: manual, legacyPoint: nil, displays: alone)!
    precondition(fallback.displayIndex == 0 && fallback.manualTopCenter == CGPoint(x: 546, y: 383))
    // A manual point without identity selects the display containing it, else the target; point as saved.
    let legacyManual = PanelManualPlacement(topCenter: CGPoint(x: 100, y: 1500), anchor: nil)
    precondition(PanelPlacementResolver.resolve(preferences: primary, manual: legacyManual, legacyPoint: nil, displays: [builtIn, dell])?.displayIndex == 1)
    precondition(PanelPlacementResolver.resolve(preferences: primary, manual: legacyManual, legacyPoint: nil, displays: alone) == PanelPlacementResolution(displayIndex: 0, manualTopCenter: CGPoint(x: 100, y: 1500), isNotchLocked: false))
    // Legacy `panelPosition` picks the display it was on before migration, without manual placement.
    let legacy = PanelPlacementResolver.resolve(preferences: primary, manual: nil, legacyPoint: CGPoint(x: 0, y: 1200), displays: [builtIn, dell])!
    precondition(legacy.displayIndex == 1 && legacy.manualTopCenter == nil)

    // Explicit target lock overrides both manual forms and legacy placement, without changing any saved intent.
    let locked = PanelPlacementPreferences(displayUUID: builtInUUID.lowercased(), lockToNotch: true)
    for displays in [[builtIn, dell], [dell, builtIn], [dell.withPrimary(true), builtIn.withPrimary(false)]] {
        for saved in [manual, legacyManual] {
            let resolution = PanelPlacementResolver.resolve(preferences: locked, manual: saved,
                                                            legacyPoint: legacyManual.topCenter, displays: displays)!
            precondition(displays[resolution.displayIndex].uuid == builtInUUID)
            precondition(resolution.isNotchLocked && resolution.manualTopCenter == nil)
        }
        let legacyLocked = PanelPlacementResolver.resolve(preferences: locked, manual: nil,
                                                          legacyPoint: legacyManual.topCenter, displays: displays)!
        precondition(legacyLocked.isNotchLocked && displays[legacyLocked.displayIndex].uuid == builtInUUID)
    }
    let unlocked = PanelPlacementPreferences(displayUUID: builtInUUID)
    precondition(PanelPlacementResolver.resolve(preferences: unlocked, manual: manual, legacyPoint: nil,
                                               displays: [builtIn, dell])?.manualTopCenter == manual.topCenter)
    // Nil UUID is never locked, even if primary is notched; an external selection never picks another notch.
    for preferences in [PanelPlacementPreferences(lockToNotch: true),
                        PanelPlacementPreferences(displayUUID: dellUUID, lockToNotch: true)] {
        let resolution = PanelPlacementResolver.resolve(preferences: preferences, manual: manual,
                                                        legacyPoint: nil, displays: [builtIn, dell])!
        precondition(!resolution.isNotchLocked && resolution.manualTopCenter == manual.topCenter)
    }
    // Disconnect, an empty transient inventory, a notched fallback, and reconnect preserve the UUID and anchor.
    precondition(PanelPlacementResolver.resolve(preferences: locked, manual: manual, legacyPoint: nil, displays: []) == nil)
    let away = PanelPlacementResolver.resolve(preferences: locked, manual: manual, legacyPoint: nil, displays: [dell])!
    precondition(!away.isNotchLocked && away.manualTopCenter == manual.topCenter)
    let missing = PanelPlacementPreferences(displayUUID: "DISCONNECTED", lockToNotch: true)
    precondition(!PanelPlacementResolver.resolve(preferences: missing, manual: manual, legacyPoint: nil,
                                                displays: [builtIn])!.isNotchLocked)
    precondition(PanelPlacementResolver.resolve(preferences: locked, manual: manual, legacyPoint: nil,
                                               displays: [dell, builtIn])!.isNotchLocked)

    // Preferences store: reading writes nothing, prepare is pure, savePrepared persists and survives a restart.
    let (defaults, cleanup) = isolatedDefaults()
    defer { cleanup() }
    let store = PanelPlacementPreferencesStore(defaults: defaults)
    precondition(store.preferences == .defaults && defaults.data(forKey: PanelPlacementPreferencesStore.storageKey) == nil)
    let prepared = try! store.prepare(PanelPlacementPreferences(displayUUID: "  " + dellUUID.lowercased() + " "))
    precondition(store.preferences == .defaults && defaults.data(forKey: PanelPlacementPreferencesStore.storageKey) == nil)
    store.savePrepared(prepared)
    precondition(store.preferences == explicitDell)
    precondition(PanelPlacementPreferencesStore(defaults: defaults).preferences == explicitDell)
    store.savePrepared(try! store.prepare(PanelPlacementPreferences(displayUUID: "   ")))
    precondition(PanelPlacementPreferencesStore(defaults: defaults).preferences == .defaults)

    // Previous v1 payloads keep the selected monitor and default the new lock to false, without a write.
    let oldData = Data("{\"displayUUID\":\"\(dellUUID.lowercased())\"}".utf8)
    defaults.set(oldData, forKey: PanelPlacementPreferencesStore.storageKey)
    precondition(PanelPlacementPreferencesStore(defaults: defaults).preferences == explicitDell)
    precondition(defaults.data(forKey: PanelPlacementPreferencesStore.storageKey) == oldData)
    defaults.set(Data("{}".utf8), forKey: PanelPlacementPreferencesStore.storageKey)
    precondition(PanelPlacementPreferencesStore(defaults: defaults).preferences == .defaults)
    let primaryLockData = Data("{\"lockToNotch\":true}".utf8)
    defaults.set(primaryLockData, forKey: PanelPlacementPreferencesStore.storageKey)
    precondition(PanelPlacementPreferencesStore(defaults: defaults).preferences == PanelPlacementPreferences(lockToNotch: true))
    precondition(defaults.data(forKey: PanelPlacementPreferencesStore.storageKey) == primaryLockData, "an inactive saved primary lock is not silently normalized")
    let lockPrepared = try! store.prepare(locked)
    precondition(lockPrepared.preferences.displayUUID == builtInUUID && lockPrepared.preferences.lockToNotch)
    store.savePrepared(lockPrepared)
    precondition(PanelPlacementPreferencesStore(defaults: defaults).preferences == locked.normalized)

    // Manual store: legacy startup preserves coordinates; clear removes every manual form.
    let (manualDefaults, manualCleanup) = isolatedDefaults()
    defer { manualCleanup() }
    manualDefaults.set([512.5, 900.0], forKey: PanelManualPlacementStore.positionKey)
    manualDefaults.set([40.0, 20.0], forKey: PanelManualPlacementStore.legacyKey)
    let manualStore = PanelManualPlacementStore(defaults: manualDefaults)
    precondition(manualStore.placement == PanelManualPlacement(topCenter: CGPoint(x: 512.5, y: 900), anchor: nil))
    precondition(manualStore.legacyPanelPosition == CGPoint(x: 40, y: 20))
    precondition(manualDefaults.array(forKey: PanelManualPlacementStore.positionKey) as? [Double] == [512.5, 900])
    manualStore.save(manual)
    precondition(PanelManualPlacementStore(defaults: manualDefaults).placement == manual)
    manualStore.clear()
    precondition(manualStore.placement == nil && manualStore.legacyPanelPosition == nil)

    // Settings consumes this same save decision before adopting preferences and clearing manual storage.
    // A checked lock is insufficient: the newly selected target must actually have a measurable notch.
    let savedOnBuiltIn = PanelManualPlacement(
        topCenter: CGPoint(x: 600, y: 800),
        anchor: PanelManualPlacement.Anchor(displayUUID: builtInUUID, offset: CGPoint(x: 600, y: 800)))
    let lockedBuiltIn = locked.normalized
    let lockedDell = PanelPlacementPreferences(displayUUID: dellUUID, lockToNotch: true)
    let lockedPrimary = PanelPlacementPreferences(lockToNotch: true)
    let notchlessBuiltIn = PlacementDisplay(uuid: builtInUUID, frame: builtIn.frame, isPrimary: true,
                                           name: builtIn.name, hasNotch: false)
    let saveCases: [(name: String, previous: PanelPlacementPreferences, next: PanelPlacementPreferences,
                     displays: [PlacementDisplay], clears: Bool, target: String, locked: Bool)] = [
        ("checked external target", lockedBuiltIn, lockedDell, [builtIn, dell], true, dellUUID, false),
        ("checked system primary", lockedBuiltIn, lockedPrimary,
         [builtIn.withPrimary(false), dell.withPrimary(true)], true, dellUUID, false),
        ("disconnected target with notched fallback", primary, missing, [builtIn, dell], true, builtInUUID, false),
        ("target without notch measurements", explicitDell, lockedBuiltIn,
         [notchlessBuiltIn, dell], true, builtInUUID, false),
        ("select target and enable lock together", primary, lockedBuiltIn, [dell, builtIn], false, builtInUUID, true),
        ("unlocked monitor change", primary, explicitDell, [builtIn, dell], true, dellUUID, false),
        ("enable lock only", unlocked, lockedBuiltIn, [builtIn, dell], false, builtInUUID, true),
        ("disable lock only", lockedBuiltIn, unlocked, [builtIn, dell], false, builtInUUID, false),
        ("enable inactive lock only", explicitDell, lockedDell, [builtIn, dell], false, builtInUUID, false),
        ("disable inactive lock only", lockedDell, explicitDell, [builtIn, dell], false, builtInUUID, false),
    ]
    for test in saveCases {
        store.savePrepared(try! store.prepare(test.previous))
        manualStore.save(savedOnBuiltIn)
        manualDefaults.set([40.0, 20.0], forKey: PanelManualPlacementStore.legacyKey)
        let next = try! store.prepare(test.next)
        let clearManual = PanelPlacementResolver.shouldClearManualPlacement(
            from: store.preferences, to: next.preferences, displays: test.displays)
        precondition(clearManual == test.clears, test.name)
        store.savePrepared(next)
        if clearManual { manualStore.clear() }
        let reloadedManual = PanelManualPlacementStore(defaults: manualDefaults)
        precondition(reloadedManual.placement == (test.clears ? nil : savedOnBuiltIn), test.name)
        precondition(reloadedManual.legacyPanelPosition == (test.clears ? nil : CGPoint(x: 40, y: 20)), test.name)
        let preferences = PanelPlacementPreferencesStore(defaults: defaults).preferences
        precondition(preferences == test.next.normalized, test.name)
        let resolution = PanelPlacementResolver.resolve(
            preferences: preferences, manual: reloadedManual.placement,
            legacyPoint: reloadedManual.legacyPanelPosition, displays: test.displays)!
        precondition(test.displays[resolution.displayIndex].uuid == test.target, test.name)
        precondition(resolution.isNotchLocked == test.locked, test.name)
        precondition(resolution.manualTopCenter == (test.clears || test.locked ? nil : savedOnBuiltIn.topCenter), test.name)
        if test.locked {
            let restored = PanelPlacementResolver.resolve(
                preferences: PanelPlacementPreferences(displayUUID: preferences.displayUUID),
                manual: reloadedManual.placement, legacyPoint: reloadedManual.legacyPanelPosition,
                displays: test.displays)!
            precondition(restored.manualTopCenter == savedOnBuiltIn.topCenter, test.name)
        }
    }
    precondition(PanelPlacementResolver.shouldClearManualPlacement(from: primary, to: lockedBuiltIn, displays: []))
    precondition(!PanelPlacementResolver.shouldClearManualPlacement(from: unlocked, to: lockedBuiltIn, displays: []))
    // Corrupt values read as absent rather than as a bogus position.
    manualDefaults.set([Double.nan, 1.0], forKey: PanelManualPlacementStore.positionKey)
    precondition(manualStore.placement == nil)
}

private extension PlacementDisplay {
    func withPrimary(_ value: Bool) -> PlacementDisplay {
        PlacementDisplay(uuid: uuid, frame: frame, isPrimary: value, name: name, hasNotch: hasNotch)
    }
}
