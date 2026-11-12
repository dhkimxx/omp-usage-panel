import AppKit

/// A fresh snapshot of the connected displays. `displays[i]` describes `screens[i]`; NSScreen objects are never
/// retained across calls, and NSScreen.main (focus-dependent) is never consulted.
struct PanelScreenInventory {
    let displays: [PlacementDisplay]
    let screens: [NSScreen]

    static func current() -> PanelScreenInventory {
        let screens = NSScreen.screens
        let primaryID = CGMainDisplayID()
        let displays = screens.map { screen -> PlacementDisplay in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
            var uuid: String?
            if let id, let raw = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, raw) as String
            }
            return PlacementDisplay(uuid: uuid, frame: screen.frame, isPrimary: id == primaryID, name: screen.localizedName)
        }
        return PanelScreenInventory(displays: displays, screens: screens)
    }
}
