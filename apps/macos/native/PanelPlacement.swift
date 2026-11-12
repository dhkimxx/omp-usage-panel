import Foundation
import CoreGraphics

// Which display hosts the usage panel. Foundation-only so it is testable without AppKit.
// Identity is the display UUID (stable across reboots, reordering and the transient CGDirectDisplayID);
// names are labels only. `nil` means "System primary", the display that owns the menu bar.

enum PanelDisplayIdentity {
    static func normalize(_ uuid: String?) -> String? {
        guard let trimmed = uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }
}

struct PanelPlacementPreferences: Codable, Equatable {
    var displayUUID: String?

    init(displayUUID: String? = nil) { self.displayUUID = displayUUID }

    static let defaults = PanelPlacementPreferences()

    var normalized: PanelPlacementPreferences {
        PanelPlacementPreferences(displayUUID: PanelDisplayIdentity.normalize(displayUUID))
    }
}

/// One selectable connected display for Settings.
struct PanelDisplayChoice: Equatable {
    let uuid: String
    let name: String
    let isPrimary: Bool
}

/// Created only by `PanelPlacementPreferencesStore.prepare(_:)`, so `savePrepared` has no throwing step left.
struct PreparedPanelPlacementPreferences: Equatable {
    let preferences: PanelPlacementPreferences
    let data: Data

    fileprivate init(preferences: PanelPlacementPreferences, data: Data) {
        self.preferences = preferences
        self.data = data
    }
}

final class PanelPlacementPreferencesStore {
    static let storageKey = "panelPlacement.v1"
    private let defaults: UserDefaults
    private(set) var preferences: PanelPlacementPreferences

    /// Reading never writes.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: PanelPlacementPreferencesStore.storageKey),
           let decoded = try? JSONDecoder().decode(PanelPlacementPreferences.self, from: data) {
            preferences = decoded.normalized
        } else {
            preferences = .defaults
        }
    }

    func prepare(_ preferences: PanelPlacementPreferences) throws -> PreparedPanelPlacementPreferences {
        let normalized = preferences.normalized
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return PreparedPanelPlacementPreferences(preferences: normalized, data: try encoder.encode(normalized))
    }

    func savePrepared(_ prepared: PreparedPanelPlacementPreferences) {
        defaults.set(prepared.data, forKey: PanelPlacementPreferencesStore.storageKey)
        preferences = prepared.preferences
    }
}

/// A connected display as the resolver sees it. `uuid` is nil only if the system cannot report one.
struct PlacementDisplay: Equatable {
    let uuid: String?
    let frame: CGRect
    let isPrimary: Bool
    let name: String

    init(uuid: String?, frame: CGRect, isPrimary: Bool, name: String) {
        self.uuid = PanelDisplayIdentity.normalize(uuid)
        self.frame = frame
        self.isPrimary = isPrimary
        self.name = name
    }
}

/// A user-chosen (Option-drag) position. The global point is kept as saved; the anchor records which display it
/// belongs to and where on it, so a reconnected display regains the panel even if it was rearranged meanwhile.
struct PanelManualPlacement: Equatable {
    struct Anchor: Equatable {
        var displayUUID: String
        var offset: CGPoint
    }
    var topCenter: CGPoint
    var anchor: Anchor?
}

/// App-wide manual position storage (`dockTopCenter`, its display anchor, and the legacy `panelPosition`).
final class PanelManualPlacementStore {
    static let positionKey = "dockTopCenter"
    static let anchorKey = "dockTopCenterDisplay"
    static let legacyKey = "panelPosition"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func point(_ values: [Double]?) -> CGPoint? {
        guard let values, values.count == 2, values.allSatisfy({ $0.isFinite }) else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    var placement: PanelManualPlacement? {
        guard let point = PanelManualPlacementStore.point(defaults.array(forKey: PanelManualPlacementStore.positionKey) as? [Double]) else { return nil }
        var anchor: PanelManualPlacement.Anchor?
        if let raw = defaults.dictionary(forKey: PanelManualPlacementStore.anchorKey),
           let uuid = PanelDisplayIdentity.normalize(raw["uuid"] as? String),
           let x = raw["x"] as? Double, let y = raw["y"] as? Double, x.isFinite, y.isFinite {
            anchor = PanelManualPlacement.Anchor(displayUUID: uuid, offset: CGPoint(x: x, y: y))
        }
        return PanelManualPlacement(topCenter: point, anchor: anchor)
    }

    /// Pre-dockTopCenter format: the panel's bottom-left origin.
    var legacyPanelPosition: CGPoint? {
        PanelManualPlacementStore.point(defaults.array(forKey: PanelManualPlacementStore.legacyKey) as? [Double])
    }

    func save(_ placement: PanelManualPlacement) {
        defaults.set([Double(placement.topCenter.x), Double(placement.topCenter.y)], forKey: PanelManualPlacementStore.positionKey)
        if let anchor = placement.anchor {
            defaults.set(["uuid": anchor.displayUUID, "x": Double(anchor.offset.x), "y": Double(anchor.offset.y)],
                         forKey: PanelManualPlacementStore.anchorKey)
        } else {
            defaults.removeObject(forKey: PanelManualPlacementStore.anchorKey)
        }
    }

    /// Clears every manual form, including an unmigrated legacy position. The configured display is untouched.
    func clear() {
        defaults.removeObject(forKey: PanelManualPlacementStore.positionKey)
        defaults.removeObject(forKey: PanelManualPlacementStore.anchorKey)
        defaults.removeObject(forKey: PanelManualPlacementStore.legacyKey)
    }

    func removeLegacy() { defaults.removeObject(forKey: PanelManualPlacementStore.legacyKey) }
}

struct PanelPlacementResolution: Equatable {
    /// Index into the display inventory that was resolved against.
    let displayIndex: Int
    /// Effective global top-center for the geometry; nil selects automatic placement. Never persisted.
    let manualTopCenter: CGPoint?
}

enum PanelPlacementResolver {
    private static func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    static func containingIndex(_ point: CGPoint, in displays: [PlacementDisplay]) -> Int? {
        displays.firstIndex { contains($0.frame, point) }
    }

    static func primaryIndex(in displays: [PlacementDisplay]) -> Int? {
        displays.firstIndex { $0.isPrimary } ?? (displays.isEmpty ? nil : 0)
    }

    /// The configured display, or the system primary while the configured one is disconnected.
    /// Focus, window order and inventory order never participate.
    static func targetIndex(_ preferences: PanelPlacementPreferences, in displays: [PlacementDisplay]) -> Int? {
        if let uuid = PanelDisplayIdentity.normalize(preferences.displayUUID),
           let index = displays.firstIndex(where: { $0.uuid == uuid }) {
            return index
        }
        return primaryIndex(in: displays)
    }

    static func resolve(preferences: PanelPlacementPreferences, manual: PanelManualPlacement?, legacyPoint: CGPoint?,
                        displays: [PlacementDisplay]) -> PanelPlacementResolution? {
        guard let target = targetIndex(preferences, in: displays) else { return nil }
        if let manual {
            if let anchor = manual.anchor {
                if let index = displays.firstIndex(where: { $0.uuid == anchor.displayUUID }) {
                    return PanelPlacementResolution(displayIndex: index, manualTopCenter: point(anchor.offset, on: displays[index]))
                }
                // Anchor display is away: show on the fallback at the same relative spot; saved data stays as is.
                return PanelPlacementResolution(displayIndex: target, manualTopCenter: point(anchor.offset, on: displays[target]))
            }
            let index = containingIndex(manual.topCenter, in: displays) ?? target
            return PanelPlacementResolution(displayIndex: index, manualTopCenter: manual.topCenter)
        }
        if let legacyPoint, let index = containingIndex(legacyPoint, in: displays) {
            return PanelPlacementResolution(displayIndex: index, manualTopCenter: nil)
        }
        return PanelPlacementResolution(displayIndex: target, manualTopCenter: nil)
    }

    private static func point(_ offset: CGPoint, on display: PlacementDisplay) -> CGPoint {
        CGPoint(x: display.frame.minX + offset.x, y: display.frame.minY + offset.y)
    }

    /// Anchors a global point to the display that contains it, if that display has an identity.
    static func anchor(for point: CGPoint, on display: PlacementDisplay) -> PanelManualPlacement.Anchor? {
        guard let uuid = display.uuid, contains(display.frame, point) else { return nil }
        return PanelManualPlacement.Anchor(displayUUID: uuid, offset: CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY))
    }

    /// Selectable displays: primary first, then by raw name and UUID, independent of inventory order.
    /// Names are labels only; disambiguating equal names is the Settings UI's job.
    static func choices(_ displays: [PlacementDisplay]) -> [PanelDisplayChoice] {
        displays
            .compactMap { display in display.uuid.map { PanelDisplayChoice(uuid: $0, name: display.name, isPrimary: display.isPrimary) } }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.uuid < rhs.uuid
            }
    }
}
