import Foundation

enum CompactWingSide: String, Codable { case left, right }

struct CompactPreferences: Codable, Equatable {
    /// TOTAL compact controls across both wings, including the single global More control.
    var maximumVisibleSlots: Int
    /// nil = never initialized (eligible for the delayed first seed); [] = explicitly none.
    var selectedProviderIDs: [String]?
    /// Wing for every provider without its own override, and for the empty-selection configure control.
    var defaultSide: CompactWingSide
    /// Per-provider wing overrides. Entries for deselected or currently unreported providers are retained.
    var providerSides: [String: CompactWingSide]

    init(maximumVisibleSlots: Int = 3, selectedProviderIDs: [String]? = nil,
         defaultSide: CompactWingSide = .right, providerSides: [String: CompactWingSide] = [:]) {
        self.maximumVisibleSlots = maximumVisibleSlots
        self.selectedProviderIDs = selectedProviderIDs
        self.defaultSide = defaultSide
        self.providerSides = providerSides
    }

    func side(for providerID: String) -> CompactWingSide {
        providerSides.first { $0.key.isExactlyEqual(to: providerID) }?.value ?? defaultSide
    }

    private enum CodingKeys: String, CodingKey {
        case maximumVisibleSlots, selectedProviderIDs, defaultSide, providerSides
        /// Legacy global side. Decoded as the initial default; also written (= defaultSide) because the previous
        /// updater-enabled app requires it and may be restored by an automatic rollback.
        case side
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maximumVisibleSlots = try container.decode(Int.self, forKey: .maximumVisibleSlots)
        selectedProviderIDs = try container.decodeIfPresent([String].self, forKey: .selectedProviderIDs)
        // The legacy global side is only an initial default; an explicit defaultSide always wins.
        if let value = try container.decodeIfPresent(String.self, forKey: .defaultSide) {
            defaultSide = CompactWingSide(rawValue: value) ?? .right
        } else if let value = try container.decodeIfPresent(String.self, forKey: .side) {
            defaultSide = CompactWingSide(rawValue: value) ?? .right
        } else {
            defaultSide = .right
        }
        // One unrecognized value must not discard every other saved override.
        let raw = try container.decodeIfPresent([String: String].self, forKey: .providerSides) ?? [:]
        providerSides = raw.compactMapValues { CompactWingSide(rawValue: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumVisibleSlots, forKey: .maximumVisibleSlots)
        try container.encodeIfPresent(selectedProviderIDs, forKey: .selectedProviderIDs)
        try container.encode(defaultSide, forKey: .defaultSide)
        try container.encode(defaultSide, forKey: .side)
        try container.encode(providerSides, forKey: .providerSides)
    }

    /// Positive slot count and de-duplicated IDs (first occurrence wins, IDs never rewritten).
    var normalized: CompactPreferences {
        var seen = Set<ExactString>()
        let ids = selectedProviderIDs?.filter { seen.insert($0.exactKey).inserted }
        return CompactPreferences(maximumVisibleSlots: max(1, maximumVisibleSlots), selectedProviderIDs: ids,
                                  defaultSide: defaultSide, providerSides: providerSides)
    }

    /// Human summary of how `selectedCount` providers fit into `maximum` total slots (More occupies one slot).
    static func capacitySummary(selectedCount: Int, maximum: Int) -> String {
        let slots = max(1, maximum)
        let count = max(0, selectedCount)
        if count == 0 { return "No providers selected. The compact row shows a + button to open these settings." }
        if count <= slots { return "\(count) of \(slots) slots used: every selected provider gets its own ring." }
        if slots == 1 { return "1 slot: only a More button (+\(count)) is shown." }
        return "\(count) selected, \(slots) slots: \(slots - 1) rings plus More +\(count - slots + 1)."
    }
}

struct CompactProviderChoice: Equatable {
    let id: String
    let label: String
    let detail: String?
    let isReported: Bool

    init(id: String, label: String, detail: String? = nil, isReported: Bool = true) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isReported = isReported
    }
}

/// Normalized preferences together with their exact stored encoding. Only
/// `CompactPreferencesStore.prepare(_:)` creates one, so `savePrepared` has no throwing step left.
struct PreparedCompactPreferences: Equatable {
    let preferences: CompactPreferences
    let data: Data

    fileprivate init(preferences: CompactPreferences, data: Data) {
        self.preferences = preferences
        self.data = data
    }
}

final class CompactPreferencesStore {
    private let defaults: UserDefaults
    private let key: String
    private(set) var preferences: CompactPreferences

    /// Reading never writes: a legacy value (global `side`) is migrated in memory only and rewritten
    /// in the new shape the next time something is explicitly saved.
    init(defaults: UserDefaults = .standard, configPath: String, profile: String) {
        self.defaults = defaults
        self.key = CompactPreferencesStore.storageKey(configPath: configPath, profile: profile)
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(CompactPreferences.self, from: data) {
            preferences = decoded.normalized
        } else {
            preferences = CompactPreferences()
        }
    }

    /// Unambiguous composite: JSON array of [standardized path, normalized profile], base64 encoded.
    static func storageKey(configPath: String, profile: String) -> String {
        let path = (configPath as NSString).standardizingPath
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let composite = (try? JSONEncoder().encode([path, trimmed.isEmpty ? "default" : trimmed])) ?? Data()
        return "compactPreferences.v1." + composite.base64EncodedString()
    }

    /// Normalizes and encodes without touching memory or defaults.
    func prepare(_ preferences: CompactPreferences) throws -> PreparedCompactPreferences {
        let normalized = preferences.normalized
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return PreparedCompactPreferences(preferences: normalized, data: try encoder.encode(normalized))
    }

    /// Cannot fail: memory and defaults change together, after encoding already succeeded.
    func savePrepared(_ prepared: PreparedCompactPreferences) {
        defaults.set(prepared.data, forKey: key)
        preferences = prepared.preferences
    }

    /// First eligible report seeds up to `maximumVisibleSlots` distinct providers, once. Unknown/unavailable
    /// reports are excluded from the automatic seed only; known 0% qualifies. Nothing changes if the seed
    /// cannot be encoded.
    @discardableResult
    func initializeSelectionIfNeeded(summaries: [ProviderSummary]) -> Bool {
        guard preferences.selectedProviderIDs == nil else { return false }
        var seen = Set<ExactString>()
        var seed: [String] = []
        for summary in summaries {
            if seed.count >= preferences.maximumVisibleSlots { break }
            guard summary.accountCount > 0, let percent = summary.percent, percent.isFinite, percent >= 0 else { continue }
            if seen.insert(summary.provider.exactKey).inserted { seed.append(summary.provider) }
        }
        guard !seed.isEmpty else { return false }
        var updated = preferences
        updated.selectedProviderIDs = seed
        guard let prepared = try? prepare(updated) else { return false }
        savePrepared(prepared)
        return true
    }
}
