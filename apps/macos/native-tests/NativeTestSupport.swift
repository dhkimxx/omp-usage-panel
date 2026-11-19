import Foundation

/// A throwaway UserDefaults domain that never touches the real ~/Library/Preferences. The suite name is an absolute
/// path inside a private temporary directory, so the plist cfprefsd writes (also lazily, after a domain is removed)
/// lives there and `cleanup` deletes the whole directory.
func makeIsolatedDefaults(prefix: String) -> (defaults: UserDefaults, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = directory.appendingPathComponent("defaults").path
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    })
}
