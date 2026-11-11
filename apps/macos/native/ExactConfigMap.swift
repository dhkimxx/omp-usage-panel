import Foundation

/// Exact string identity: two strings are the same iff they have the same Unicode scalars (equivalently the same
/// UTF-16 code units), as in JavaScript. Swift's `==` is canonical equivalence ("é" == "e\u{301}"), which would
/// merge distinct provider/limit IDs, so configuration never relies on it.
extension String {
    func isExactlyEqual(to other: String) -> Bool { utf8.elementsEqual(other.utf8) }
    /// Hashable wrapper with exact identity, for `Set`/`Dictionary` keys. Allocation-free.
    var exactKey: ExactString { ExactString(self) }
}

/// A `String` that is `Hashable` and `Equatable` by exact UTF-8 (scalar) identity instead of canonical equivalence.
struct ExactString: Hashable {
    let value: String
    init(_ value: String) { self.value = value }

    static func == (lhs: ExactString, rhs: ExactString) -> Bool { lhs.value.isExactlyEqual(to: rhs.value) }
    func hash(into hasher: inout Hasher) {
        for byte in value.utf8 { hasher.combine(byte) }
        hasher.combine(0xFF as UInt8)
    }
}

/// Insertion-ordered string map keyed by *exact* strings (see above), used for `PanelConfig.labels` and `.metrics`.
/// Dictionary-literal, `subscript(key)`, `keys`/`values` and RandomAccessCollection semantics (`(key:, value:)`
/// elements), but it never merges keys that Swift considers canonically equivalent. Equality ignores order, like a
/// JSON object, and compares keys and values exactly.
struct ExactConfigMap: RandomAccessCollection, ExpressibleByDictionaryLiteral, Equatable {
    typealias Element = (key: String, value: String)
    typealias Index = Int
    typealias Keys = LazyMapCollection<[Element], String>
    typealias Values = LazyMapCollection<[Element], String>

    private(set) var entries: [Element] = []

    init() {}
    /// Later duplicates (exact) replace earlier ones, keeping the first position, like JS object assignment.
    init(_ pairs: [Element]) { for pair in pairs { self[pair.key] = pair.value } }
    init(dictionaryLiteral elements: (String, String)...) { for (key, value) in elements { self[key] = value } }

    var startIndex: Int { 0 }
    var endIndex: Int { entries.count }
    subscript(position: Int) -> Element { entries[position] }

    subscript(key: String) -> String? {
        get { entries.first { $0.key.isExactlyEqual(to: key) }?.value }
        set {
            let index = entries.firstIndex { $0.key.isExactlyEqual(to: key) }
            switch (index, newValue) {
            case (let index?, let value?): entries[index].value = value
            case (let index?, nil): entries.remove(at: index)
            case (nil, let value?): entries.append((key: key, value: value))
            case (nil, nil): break
            }
        }
    }

    /// Lazy views (like `Dictionary.Keys`): no array is built per access.
    var keys: Keys { entries.lazy.map(\.key) }
    var values: Values { entries.lazy.map(\.value) }
    /// Deterministic order (by UTF-8 bytes, a total order on exact strings) for persistence and editors.
    var sortedEntries: [Element] { entries.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) } }

    static func == (lhs: ExactConfigMap, rhs: ExactConfigMap) -> Bool {
        lhs.count == rhs.count && lhs.entries.allSatisfy { entry in rhs[entry.key].map { $0.isExactlyEqual(to: entry.value) } ?? false }
    }
}
