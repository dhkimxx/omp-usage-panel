import Foundation
import CoreGraphics

private let builtInUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
private let dellUUID = "63FD4F17-3FBA-46CD-AD01-70F294053371"
private let builtIn = PlacementDisplay(uuid: builtInUUID, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isPrimary: true, name: "Built-in Retina Display")
private let dell = PlacementDisplay(uuid: dellUUID, frame: CGRect(x: -446, y: 1117, width: 1920, height: 1080), isPrimary: false, name: "DELL U2417H")

private func isolatedDefaults() -> UserDefaults {
    let name = "omp-placement-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

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
    let twinA = PlacementDisplay(uuid: "AAAAAAAA-0000-0000-0000-000000000001", frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), isPrimary: false, name: "DELL U2417H")
    let twinB = PlacementDisplay(uuid: "AAAAAAAA-0000-0000-0000-000000000002", frame: CGRect(x: 3648, y: 0, width: 1920, height: 1080), isPrimary: false, name: "DELL U2417H")
    let twins = [builtIn, twinB, twinA]
    let pickB = PanelPlacementPreferences(displayUUID: twinB.uuid)
    precondition(twins[PanelPlacementResolver.targetIndex(pickB, in: twins)!] == twinB)
    let choices = PanelPlacementResolver.choices(twins)
    precondition(choices.map(\.uuid) == [builtInUUID, twinA.uuid!, twinB.uuid!])
    precondition(choices.filter(\.isPrimary).count == 1 && choices[0].isPrimary)
    precondition(PanelPlacementResolver.choices([dell, builtIn]) == PanelPlacementResolver.choices([builtIn, dell]))

    // Disconnect: the target falls back to primary but the preference itself is a value that never changes.
    let before = explicitDell
    let alone = [builtIn]
    precondition(PanelPlacementResolver.resolve(preferences: before, manual: nil, legacyPoint: nil, displays: alone)?.displayIndex == 0)
    precondition(before == explicitDell)
    // Reconnect, even with the displays renumbered into a different order: back on the configured display.
    precondition(PanelPlacementResolver.resolve(preferences: before, manual: nil, legacyPoint: nil, displays: [dell, builtIn])?.displayIndex == 0)

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
    let moved = PlacementDisplay(uuid: dellUUID, frame: CGRect(x: 2000, y: -300, width: 1920, height: 1080), isPrimary: false, name: "DELL U2417H")
    let following = PanelPlacementResolver.resolve(preferences: primary, manual: manual, legacyPoint: nil, displays: [builtIn, moved])!
    precondition(following.displayIndex == 1 && following.manualTopCenter == CGPoint(x: 2546, y: 83))
    // Disconnected anchor: shown on the fallback at the same relative spot; the saved manual value is not touched.
    let fallback = PanelPlacementResolver.resolve(preferences: primary, manual: manual, legacyPoint: nil, displays: alone)!
    precondition(fallback.displayIndex == 0 && fallback.manualTopCenter == CGPoint(x: 546, y: 383))
    precondition(manual.topCenter == CGPoint(x: 100, y: 1500) && manual.anchor == anchor)
    // A manual point without identity selects the display containing it, else the target; point as saved.
    let legacyManual = PanelManualPlacement(topCenter: CGPoint(x: 100, y: 1500), anchor: nil)
    precondition(PanelPlacementResolver.resolve(preferences: primary, manual: legacyManual, legacyPoint: nil, displays: [builtIn, dell])?.displayIndex == 1)
    precondition(PanelPlacementResolver.resolve(preferences: primary, manual: legacyManual, legacyPoint: nil, displays: alone) == PanelPlacementResolution(displayIndex: 0, manualTopCenter: CGPoint(x: 100, y: 1500)))
    // Legacy `panelPosition` picks the display it was on before migration, without manual placement.
    let legacy = PanelPlacementResolver.resolve(preferences: primary, manual: nil, legacyPoint: CGPoint(x: 0, y: 1200), displays: [builtIn, dell])!
    precondition(legacy.displayIndex == 1 && legacy.manualTopCenter == nil)

    // Preferences store: reading writes nothing, prepare is pure, savePrepared persists and survives a restart.
    let defaults = isolatedDefaults()
    let store = PanelPlacementPreferencesStore(defaults: defaults)
    precondition(store.preferences == .defaults && defaults.data(forKey: PanelPlacementPreferencesStore.storageKey) == nil)
    let prepared = try! store.prepare(PanelPlacementPreferences(displayUUID: "  " + dellUUID.lowercased() + " "))
    precondition(store.preferences == .defaults && defaults.data(forKey: PanelPlacementPreferencesStore.storageKey) == nil)
    store.savePrepared(prepared)
    precondition(store.preferences == explicitDell)
    precondition(PanelPlacementPreferencesStore(defaults: defaults).preferences == explicitDell)
    store.savePrepared(try! store.prepare(PanelPlacementPreferences(displayUUID: "   ")))
    precondition(PanelPlacementPreferencesStore(defaults: defaults).preferences == .defaults)

    // Manual store: legacy startup preserves coordinates; clear removes every manual form.
    let manualDefaults = isolatedDefaults()
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
    // Corrupt values read as absent rather than as a bogus position.
    manualDefaults.set([Double.nan, 1.0], forKey: PanelManualPlacementStore.positionKey)
    precondition(manualStore.placement == nil)
}

private extension PlacementDisplay {
    func withPrimary(_ value: Bool) -> PlacementDisplay {
        PlacementDisplay(uuid: uuid, frame: frame, isPrimary: value, name: name)
    }
}
