import Foundation

enum CompactWingSide: String, Codable { case left, right }

struct CompactPreferences: Codable, Equatable {
    var maximumVisibleSlots: Int
    /// nil = never initialized (eligible for the delayed first seed); [] = explicitly none.
    var selectedProviderIDs: [String]?
    var side: CompactWingSide

    init(maximumVisibleSlots: Int = 3, selectedProviderIDs: [String]? = nil, side: CompactWingSide = .right) {
        self.maximumVisibleSlots = maximumVisibleSlots
        self.selectedProviderIDs = selectedProviderIDs
        self.side = side
    }

    /// Positive slot count and de-duplicated IDs (first occurrence wins, IDs never rewritten).
    var normalized: CompactPreferences {
        var seen = Set<String>()
        let ids = selectedProviderIDs?.filter { seen.insert($0).inserted }
        return CompactPreferences(maximumVisibleSlots: max(1, maximumVisibleSlots), selectedProviderIDs: ids, side: side)
    }

    /// Human summary of how `selectedCount` providers fit into `maximum` total slots (More occupies the last slot).
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

final class CompactPreferencesStore {
    private let defaults: UserDefaults
    private let key: String
    private(set) var preferences: CompactPreferences

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

    func save(_ preferences: CompactPreferences) {
        let normalized = preferences.normalized
        self.preferences = normalized
        if let data = try? JSONEncoder().encode(normalized) { defaults.set(data, forKey: key) }
    }

    /// First eligible report seeds up to `maximumVisibleSlots` distinct providers, once. Unknown/unavailable
    /// reports are excluded from the automatic seed only; known 0% qualifies.
    @discardableResult
    func initializeSelectionIfNeeded(summaries: [ProviderSummary]) -> Bool {
        guard preferences.selectedProviderIDs == nil else { return false }
        var seen = Set<String>()
        var seed: [String] = []
        for summary in summaries {
            if seed.count >= preferences.maximumVisibleSlots { break }
            guard summary.accountCount > 0, let percent = summary.percent, percent.isFinite, percent >= 0 else { continue }
            if seen.insert(summary.provider).inserted { seed.append(summary.provider) }
        }
        guard !seed.isEmpty else { return false }
        var updated = preferences
        updated.selectedProviderIDs = seed
        save(updated)
        return true
    }
}
