import Foundation

private func makeConfig(
    nodePath: String = "/usr/bin/node", ompPath: String = "/usr/local/bin/omp", profile: String = "default",
    refreshSeconds: Double = 60, cacheMinutes: Double = 5, timeoutSeconds: Double = 25,
    providers: [String]? = nil, labels: ExactConfigMap = [:], metrics: ExactConfigMap = [:],
    warnPercent: Double = 70, criticalPercent: Double = 90, showPace: Bool = true
) -> PanelConfig {
    PanelConfig(version: 1, nodePath: nodePath, ompPath: ompPath, profile: profile, refreshSeconds: refreshSeconds,
                cacheMinutes: cacheMinutes, timeoutSeconds: timeoutSeconds, providers: providers, labels: labels,
                metrics: metrics, warnPercent: warnPercent, criticalPercent: criticalPercent, showPace: showPace)
}

/// Strict schema parity with apps/macos/config.mjs, the null-vs-[] distinction, and the store's save contract.
func runPanelConfigStoreTests() throws {
    // MARK: Schema (decoder)
    let base: [String: Any] = [
        "version": 1, "nodePath": "/usr/bin/node", "ompPath": "/usr/local/bin/omp", "profile": "default",
        "refreshSeconds": 60, "cacheMinutes": 5, "timeoutSeconds": 25, "providers": NSNull(),
        "labels": [String: String](), "metrics": [String: String](), "warnPercent": 70, "criticalPercent": 90, "showPace": true,
    ]
    func decodeData(_ data: Data) throws -> PanelConfig { try PanelConfigStore.decode(data) }
    func decodeObject(_ object: Any) throws -> PanelConfig { try decodeData(JSONSerialization.data(withJSONObject: object)) }
    func with(_ key: String, _ value: Any, extra: [String: Any] = [:]) -> [String: Any] {
        var object = base
        object[key] = value
        for (extraKey, extraValue) in extra { object[extraKey] = extraValue }
        return object
    }
    func accepts(_ key: String, _ value: Any, extra: [String: Any] = [:]) -> Bool {
        (try? decodeObject(with(key, value, extra: extra))) != nil
    }

    let parsedBase = try decodeObject(base)
    precondition(parsedBase == makeConfig(), "all-defaults object decodes")
    precondition(parsedBase.providers == nil, "explicit null providers decode to automatic")

    for key in base.keys {
        var missing = base
        missing[key] = nil
        precondition((try? decodeObject(missing)) == nil, "missing \(key) must be rejected")
    }
    var withExtra = base
    withExtra["unexpected"] = 1
    precondition((try? decodeObject(withExtra)) == nil, "unknown top-level key rejected")
    for document in ["null", "[]", "\"x\"", "7", "{"] {
        precondition((try? decodeData(Data(document.utf8))) == nil, "non-object or malformed document rejected: \(document)")
    }

    // version: exactly the number 1; booleans and strings are not numbers.
    precondition(!accepts("version", 2) && !accepts("version", 0) && !accepts("version", "1") && !accepts("version", true) && !accepts("version", 1.5) && !accepts("version", NSNull()))
    precondition(accepts("version", 1.0), "1.0 is the JS number 1")

    // Paths and profile: nonblank; paths absolute; raw padded profile preserved.
    for key in ["nodePath", "ompPath"] {
        precondition(!accepts(key, "node") && !accepts(key, "./node") && !accepts(key, "") && !accepts(key, "   ") && !accepts(key, 5) && !accepts(key, NSNull()) && !accepts(key, " /usr/bin/node"), "\(key) rules")
        precondition(accepts(key, "/does/not/exist/but/is/absolute"), "\(key) is not checked against disk")
    }
    precondition(!accepts("profile", "") && !accepts("profile", " \t\u{00A0}\u{FEFF} ") && !accepts("profile", 1) && !accepts("profile", NSNull()))
    let paddedProfile = try decodeObject(with("profile", "  work  "))
    precondition(paddedProfile.profile == "  work  ", "profile kept raw")

    // Numbers: finite, ranges, fractions allowed, overflow after unit conversion rejected, bool/string are not numbers.
    for key in ["refreshSeconds", "timeoutSeconds"] {
        precondition(!accepts(key, 0) && !accepts(key, -1) && !accepts(key, "60") && !accepts(key, true) && !accepts(key, NSNull()), "\(key) positive")
        precondition(accepts(key, 0.25) && accepts(key, 7.5), "\(key) fractions allowed")
        precondition(!accepts(key, 1e306) && accepts(key, 1e300), "\(key) *1000 must stay finite")
    }
    precondition(!accepts("cacheMinutes", -0.5) && !accepts("cacheMinutes", "5") && !accepts("cacheMinutes", false))
    precondition(accepts("cacheMinutes", 0) && accepts("cacheMinutes", 0.5), "cacheMinutes 0 and fractions valid")
    precondition(!accepts("cacheMinutes", 1e305) && accepts("cacheMinutes", 1e300), "cacheMinutes *60000 must stay finite")

    // Thresholds: warn >= 0, critical >= warn; equality and >100 valid.
    precondition(!accepts("warnPercent", -1) && !accepts("warnPercent", "70") && !accepts("warnPercent", NSNull()))
    precondition(accepts("warnPercent", 150, extra: ["criticalPercent": 250]), "no 100 ceiling")
    precondition(accepts("warnPercent", 90) && accepts("warnPercent", 0, extra: ["criticalPercent": 0]), "equality valid")
    precondition(!accepts("criticalPercent", 69.9) && !accepts("criticalPercent", "90") && !accepts("criticalPercent", NSNull()))
    precondition(!accepts("showPace", 1) && !accepts("showPace", "true") && !accepts("showPace", NSNull()) && accepts("showPace", false))

    // Providers: null automatic; [] valid; ordered, unique by exact string, nonblank, unknown IDs fine.
    precondition(accepts("providers", [String]()), "[] is valid")
    let emptyProviders = try decodeObject(with("providers", [String]()))
    precondition(emptyProviders.providers == [], "[] decodes to [] not nil")
    precondition(accepts("providers", ["mystery", "openai-codex", "OpenAI-Codex"]), "unknown IDs and case-distinct IDs are valid")
    let orderedProviders = try decodeObject(with("providers", ["z", " a ", "m"]))
    precondition(orderedProviders.providers == ["z", " a ", "m"], "order and raw IDs preserved")
    precondition(!accepts("providers", ["a", "a"]) && !accepts("providers", [""]) && !accepts("providers", ["  "]) && !accepts("providers", [1]) && !accepts("providers", "a") && !accepts("providers", [String: String]()) && !accepts("providers", [NSNull()]))

    // Maps: non-null object of nonblank strings; unknown/map-only keys fine, raw whitespace preserved.
    for key in ["labels", "metrics"] {
        precondition(!accepts(key, [String]()) && !accepts(key, NSNull()) && !accepts(key, "x") && !accepts(key, ["": "v"]) && !accepts(key, [" ": "v"]) && !accepts(key, ["k": ""]) && !accepts(key, ["k": " "]) && !accepts(key, ["k": 1]) && !accepts(key, ["k": NSNull()]), "\(key) map rules")
        precondition(accepts(key, ["never-reported": "x", "another": "y"]), "\(key) arbitrary keys valid")
        let parsed = try decodeObject(with(key, [" k ": " v "]))
        precondition((key == "labels" ? parsed.labels : parsed.metrics) == [" k ": " v "], "\(key) raw entries preserved")
    }

    // Errors name the field and rule but never leak raw configuration content.
    do {
        _ = try decodeObject(with("nodePath", "SECRET-relative-path"))
        preconditionFailure("relative nodePath must throw")
    } catch {
        let message = error.localizedDescription
        precondition(message.contains("nodePath") && !message.contains("SECRET"), "error names field, hides value: \(message)")
    }

    // MARK: Serializer round trip with explicit null
    let tricky = makeConfig(providers: ["zeta", " custom ", "alpha/β"], labels: ["unreported": "Quote \" slash / unicode é", " pad ": " padded "],
                            metrics: ["map-only": "limit-1", "mistral": "monthly"], warnPercent: 0.1, criticalPercent: 1e300)
    let trickyRoundTrip = try PanelConfigStore.decode(PanelConfigStore.serialize(tricky))
    precondition(trickyRoundTrip == tricky, "serializer/decoder round trip")
    let encodedNil = try PanelConfigStore.serialize(makeConfig(providers: nil))
    let encodedObject = try JSONSerialization.jsonObject(with: encodedNil) as? [String: Any]
    precondition(encodedObject?.count == 13 && encodedObject?["providers"] is NSNull, "nil providers serialize as explicit null with all 13 keys")

    // MARK: Exact string identity (Node keeps canonically-equivalent strings distinct; Swift == does not)
    let precomposed = "\u{00E9}"
    let decomposed = "e\u{0301}"
    precondition(precomposed == decomposed && !precomposed.isExactlyEqual(to: decomposed), "fixture strings are canonically equal but exactly distinct")
    func raw(labels: String = "{}", metrics: String = "{}", providers: String = "null", profile: String = "\"default\"") -> Data {
        Data(#"{"version":1,"nodePath":"\/usr\/bin\/node","ompPath":"/usr/local/bin/omp","profile":\#(profile),"refreshSeconds":60,"cacheMinutes":5,"timeoutSeconds":25,"providers":\#(providers),"labels":\#(labels),"metrics":\#(metrics),"warnPercent":70,"criticalPercent":90,"showPace":true}"#.utf8)
    }
    let bothKeys = #"{"\u00e9":"precomposed","e\u0301":"decomposed"}"#
    let exact = try PanelConfigStore.decode(raw(labels: bothKeys, metrics: bothKeys, providers: #"["\u00e9","e\u0301"]"#))
    precondition(exact.labels.count == 2 && exact.labels[precomposed] == "precomposed" && exact.labels[decomposed] == "decomposed", "raw JSON keeps both distinct label keys")
    precondition(exact.metrics.count == 2 && exact.metrics[precomposed] == "precomposed" && exact.metrics[decomposed] == "decomposed", "raw JSON keeps both distinct metric keys")
    precondition(exact.providers?.count == 2 && exact.providers?[0].isExactlyEqual(to: precomposed) == true && exact.providers?[1].isExactlyEqual(to: decomposed) == true, "distinct provider IDs are valid and ordered")
    let reread = try PanelConfigStore.decode(PanelConfigStore.serialize(exact))
    precondition(reread == exact && reread.labels.count == 2 && reread.metrics.count == 2, "serialization keeps both exact entries")
    let literalKey = try PanelConfigStore.decode(raw(labels: "{\"\u{00E9}\":\"x\"}"))
    precondition(literalKey.labels[precomposed] == "x" && literalKey.labels[decomposed] == nil, "raw UTF-8 key equals the escaped scalar, not the decomposed one")
    let duplicateKey = try PanelConfigStore.decode(raw(labels: #"{"a":"1","b":"x","a":"2"}"#))
    precondition(duplicateKey.labels.count == 2 && duplicateKey.labels["a"] == "2", "duplicate JSON keys: last value wins like JSON.parse")
    let astral = try PanelConfigStore.decode(raw(profile: #""\ud83d\ude00 \/""#))
    precondition(astral.profile == "\u{1F600} /", "surrogate pairs and escaped slashes decode")
    for bad in [raw(profile: #""\ud83d""#), raw(profile: #""\ude00""#), raw(labels: #"{"a":"1",}"#), raw(providers: "[1,]"), raw(profile: "\"a\nb\""),
                raw(labels: #"{"a":NaN}"#), raw(providers: "01"), Data([0xEF, 0xBB, 0xBF]) + raw(), raw() + Data("x".utf8), Data([0xFF])] {
        precondition((try? PanelConfigStore.decode(bad)) == nil, "malformed JSON must be rejected")
    }

    // Equality is exact: reorderings and canonical-only differences are real changes.
    precondition(makeConfig(providers: [precomposed, decomposed]) != makeConfig(providers: [decomposed, precomposed]), "provider order of exact-distinct IDs matters")
    precondition(makeConfig(profile: precomposed) != makeConfig(profile: decomposed) && makeConfig(nodePath: "/" + precomposed) != makeConfig(nodePath: "/" + decomposed), "profile/path identity is exact")
    precondition(makeConfig(labels: [precomposed: "x"]) != makeConfig(labels: [decomposed: "x"]) && makeConfig(labels: ["k": precomposed]) != makeConfig(labels: ["k": decomposed]), "map keys and values are exact")
    precondition(makeConfig(metrics: [precomposed: "a", decomposed: "b"]) == makeConfig(metrics: [decomposed: "b", precomposed: "a"]), "map equality ignores entry order")
    precondition(makeConfig(labels: [precomposed: "a", decomposed: "b"]) != makeConfig(labels: [precomposed: "a", "other": "b"]))

    // MARK: Store
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panel-config-store-\(UUID().uuidString)")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        for child in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(child).path)
        }
        try? fileManager.removeItem(at: root)
    }
    func writeFixture(_ name: String, bytes: Data, mode: Int = 0o644) throws -> String {
        let directory = root.appendingPathComponent(name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("config.json").path
        try bytes.write(to: URL(fileURLWithPath: path))
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }
    func writeJSONFixture(_ name: String, _ object: Any) throws -> String {
        try writeFixture(name, bytes: JSONSerialization.data(withJSONObject: object))
    }
    func permissions(_ path: String) throws -> Int { (try fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    func bytes(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    func object(_ path: String) throws -> [String: Any]? { try JSONSerialization.jsonObject(with: bytes(path)) as? [String: Any] }

    // Unreadable or invalid files fail construction (startup alert path) without leaking content.
    do { _ = try PanelConfigStore(configPath: root.appendingPathComponent("absent/config.json").path); preconditionFailure("missing file must throw") } catch {}
    let invalidPath = try writeJSONFixture("invalid", with("ompPath", "SECRET-relative"))
    do { _ = try PanelConfigStore(configPath: invalidPath); preconditionFailure("invalid config must throw") }
    catch { precondition(!error.localizedDescription.contains("SECRET"), "store errors hide values") }
    let garbagePath = try writeFixture("garbage", bytes: Data(#"{"nodePath":"SECRET-value""#.utf8))
    do { _ = try PanelConfigStore(configPath: garbagePath); preconditionFailure("malformed JSON must throw") }
    catch { precondition(!error.localizedDescription.contains("SECRET"), "syntax errors hide content") }

    // Loading a valid file with automatic providers, then persisting every shape.
    let path = try writeJSONFixture("main", base)
    let store = try PanelConfigStore(configPath: path)
    precondition(store.configPath == path && store.config == makeConfig() && store.config.providers == nil)

    let custom = makeConfig(profile: "work", refreshSeconds: 0.5, cacheMinutes: 0, timeoutSeconds: 12.5, providers: ["zeta", "mystery", "openai-codex"],
                            labels: ["unreported": "Quote \" / é", "mistral": " Spaced "], metrics: ["map-only": "limit-x"],
                            warnPercent: 120, criticalPercent: 120, showPace: false)
    try store.save(custom)
    precondition(store.config == custom, "store commits after a successful write")
    let reloaded = try PanelConfigStore(configPath: path).config
    precondition(reloaded == custom, "persisted config reads back identically")
    let mode = try permissions(path)
    precondition(mode == 0o600, "private permissions even when the original file was 0644 (got \(String(mode, radix: 8)))")
    let customText = try String(contentsOfFile: path, encoding: .utf8)
    precondition(customText.hasSuffix("}\n") && !customText.contains("\\/"), "readable JSON without escaped slashes")
    let leftovers = try fileManager.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
    precondition(leftovers == ["config.json"], "no temporary files remain: \(leftovers)")

    // [] and null are distinct and both persist.
    try store.save(makeConfig(providers: []))
    var persisted = try object(path)
    precondition((persisted?["providers"] as? [Any])?.isEmpty == true && persisted?.count == 13, "[] persists as an empty array")
    let reloadedEmpty = try PanelConfigStore(configPath: path).config
    precondition(reloadedEmpty.providers == [])
    try store.save(makeConfig(providers: nil))
    persisted = try object(path)
    precondition(persisted?["providers"] is NSNull && persisted?.count == 13, "nil persists as explicit null")
    let reloadedNil = try PanelConfigStore(configPath: path).config
    precondition(reloadedNil.providers == nil)

    // Unchanged save is accepted and keeps the committed value.
    try store.save(makeConfig(providers: nil))

    // Invalid candidates throw and change neither the disk bytes nor the committed config.
    let beforeBytes = try bytes(path)
    let committed = store.config
    let invalidCandidates: [PanelConfig] = [
        makeConfig(warnPercent: 80, criticalPercent: 79), makeConfig(nodePath: "relative"), makeConfig(refreshSeconds: 0),
        makeConfig(cacheMinutes: 1e305), makeConfig(providers: ["a", "a"]), makeConfig(labels: ["": "x"]), makeConfig(metrics: ["a": " "]),
        makeConfig(refreshSeconds: .nan), makeConfig(warnPercent: .infinity, criticalPercent: .infinity),
    ]
    for candidate in invalidCandidates {
        do { try store.save(candidate); preconditionFailure("invalid candidate must not save") } catch {}
        precondition(store.config == committed, "failed validation keeps committed config")
        let afterBytes = try bytes(path)
        precondition(afterBytes == beforeBytes, "failed validation keeps disk bytes")
    }

    // Write failure: the directory vanished. Nothing is committed.
    let doomedPath = try writeJSONFixture("doomed", base)
    let doomed = try PanelConfigStore(configPath: doomedPath)
    try fileManager.removeItem(atPath: (doomedPath as NSString).deletingLastPathComponent)
    do { try doomed.save(makeConfig(profile: "other")); preconditionFailure("write into a missing directory must throw") }
    catch { precondition(error is PanelConfigError, "write failures are PanelConfigError") }
    precondition(doomed.config == makeConfig(), "failed write keeps the committed config")

    // Write failure: read-only directory leaves the original bytes (skipped when permissions do not bind, e.g. root).
    let lockedPath = try writeJSONFixture("locked", base)
    let locked = try PanelConfigStore(configPath: lockedPath)
    let lockedBytes = try bytes(lockedPath)
    let lockedDirectory = (lockedPath as NSString).deletingLastPathComponent
    try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDirectory)
    if geteuid() != 0 {
        do { try locked.save(makeConfig(profile: "other")); preconditionFailure("read-only directory must refuse the write") } catch {}
        precondition(locked.config == makeConfig(), "unwritable destination keeps committed config")
        let lockedAfter = try bytes(lockedPath)
        precondition(lockedAfter == lockedBytes, "unwritable destination keeps disk bytes")
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDirectory)

    // A symlinked config file is updated in place (the link survives).
    let linkedPath = try writeJSONFixture("linked-target", base)
    let linkDirectory = root.appendingPathComponent("linked-via")
    try fileManager.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
    let link = linkDirectory.appendingPathComponent("config.json").path
    try fileManager.createSymbolicLink(atPath: link, withDestinationPath: linkedPath)
    let linkedStore = try PanelConfigStore(configPath: link)
    try linkedStore.save(makeConfig(profile: "via-link"))
    precondition((try? fileManager.destinationOfSymbolicLink(atPath: link)) == linkedPath, "symlink preserved")
    let linkedTarget = try PanelConfigStore(configPath: linkedPath).config
    precondition(linkedTarget.profile == "via-link", "target file updated through the link")

    // Exact map entries survive an unrelated save, and a reorder of exact-distinct providers is a real change.
    let exactPath = try writeFixture("exact", bytes: raw(labels: bothKeys, metrics: bothKeys, providers: #"["\u00e9","e\u0301"]"#))
    let exactStore = try PanelConfigStore(configPath: exactPath)
    precondition(exactStore.config.labels.count == 2 && exactStore.config.metrics.count == 2)
    let withProfile = PanelConfig(version: 1, nodePath: exact.nodePath, ompPath: exact.ompPath, profile: "changed", refreshSeconds: exact.refreshSeconds,
                                  cacheMinutes: exact.cacheMinutes, timeoutSeconds: exact.timeoutSeconds, providers: exact.providers, labels: exact.labels,
                                  metrics: exact.metrics, warnPercent: exact.warnPercent, criticalPercent: exact.criticalPercent, showPace: exact.showPace)
    try exactStore.save(withProfile)
    let afterUnrelated = try PanelConfigStore(configPath: exactPath).config
    precondition(afterUnrelated == withProfile && afterUnrelated.labels.count == 2 && afterUnrelated.metrics.count == 2 && afterUnrelated.profile == "changed", "unrelated save keeps both exact entries on disk")
    let reordered = PanelConfig(version: 1, nodePath: exact.nodePath, ompPath: exact.ompPath, profile: "changed", refreshSeconds: exact.refreshSeconds,
                                cacheMinutes: exact.cacheMinutes, timeoutSeconds: exact.timeoutSeconds, providers: [decomposed, precomposed], labels: exact.labels,
                                metrics: exact.metrics, warnPercent: exact.warnPercent, criticalPercent: exact.criticalPercent, showPace: exact.showPace)
    try exactStore.save(reordered)
    let afterReorder = try PanelConfigStore(configPath: exactPath).config
    precondition(afterReorder.providers?[0].isExactlyEqual(to: decomposed) == true && afterReorder == reordered, "reordering exact-distinct providers is saved, not skipped as equal")

    // A dangling config symlink is never replaced: resolution failure writes nothing and commits nothing.
    let danglingTarget = try writeJSONFixture("dangling-target", base)
    let danglingDirectory = root.appendingPathComponent("dangling-via")
    try fileManager.createDirectory(at: danglingDirectory, withIntermediateDirectories: true)
    let danglingLink = danglingDirectory.appendingPathComponent("config.json").path
    try fileManager.createSymbolicLink(atPath: danglingLink, withDestinationPath: danglingTarget)
    let danglingStore = try PanelConfigStore(configPath: danglingLink)
    try fileManager.removeItem(atPath: (danglingTarget as NSString).deletingLastPathComponent)
    do { try danglingStore.save(makeConfig(profile: "other")); preconditionFailure("dangling link must not be written") } catch {}
    precondition((try? fileManager.destinationOfSymbolicLink(atPath: danglingLink)) == danglingTarget, "dangling symlink is left in place")
    precondition(danglingStore.config == makeConfig(), "failed resolution keeps the committed config")
    let danglingEntries = try fileManager.contentsOfDirectory(atPath: danglingDirectory.path)
    precondition(danglingEntries == ["config.json"], "no temporary or replacement file is created: \(danglingEntries)")
}
