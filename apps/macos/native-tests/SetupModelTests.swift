import Foundation

private func fakeEnvironment(home: String = "/Users/me", path: String?, files: [String: SetupFileKind], children: [String: [String]] = [:]) -> SetupDiscoveryEnvironment {
    SetupDiscoveryEnvironment(home: home, path: path, kind: { files[$0] ?? .missing }, children: { children[$0] ?? [] })
}

private let validConfigJSON = """
{"version":1,"nodePath":"/opt/n/bin/node","ompPath":"/opt/o/bin/omp","profile":"work","refreshSeconds":60,"cacheMinutes":5,"timeoutSeconds":25,"providers":null,"labels":{},"metrics":{},"warnPercent":70,"criticalPercent":90,"showPace":true}
"""

func runSetupModelTests() {
    // Launch routing: --config is the unchanged fast path; no arguments split on the canonical managed location.
    let resolve: (String) -> String = { $0 }
    let canonical = "/Users/me/Applications/OMP Usage.app"
    precondition(SetupLaunch.route(arguments: ["x", "--config", "/c.json"], bundlePath: "/Volumes/OMP/OMP Usage.app", home: "/Users/me", resolve: resolve) == .normal(configPath: "/c.json"))
    precondition(SetupLaunch.route(arguments: ["x", "--config", "/c.json"], bundlePath: canonical, home: "/Users/me", resolve: resolve) == .normal(configPath: "/c.json"))
    precondition(SetupLaunch.route(arguments: ["x"], bundlePath: canonical, home: "/Users/me", resolve: resolve) == .managedHandoff)
    precondition(SetupLaunch.route(arguments: ["x"], bundlePath: "/Volumes/OMP/OMP Usage.app", home: "/Users/me", resolve: resolve) == .setup)
    precondition(SetupLaunch.route(arguments: ["x"], bundlePath: "/Users/me/Downloads/OMP Usage.app", home: "/Users/me", resolve: resolve) == .setup)
    precondition(SetupLaunch.route(arguments: ["x"], bundlePath: "/Users/me/Applications/OMP Usage.app", home: "/Users/me", resolve: { $0.replacingOccurrences(of: "/private", with: "") }) == .managedHandoff)
    precondition(SetupLaunch.route(arguments: ["x", "--config"], bundlePath: canonical, home: "/Users/me", resolve: resolve) == .usage)
    precondition(SetupLaunch.route(arguments: ["x", "--other", "y"], bundlePath: canonical, home: "/Users/me", resolve: resolve) == .usage)
    precondition(SetupLaunch.defaultConfigPath(home: "/Users/me") == "/Users/me/Library/Application Support/omp-usage-panel/config.json")

    // Node version boundary: 22.18.0 is the first compatible release; anything not exactly vX.Y.Z is rejected.
    precondition(SetupNodeVersion.parse("v22.17.9\n")?.isCompatible == false)
    precondition(SetupNodeVersion.parse("v22.18.0\n")?.isCompatible == true)
    precondition(SetupNodeVersion.parse("v22.23.4")?.isCompatible == true)
    precondition(SetupNodeVersion.parse("v23.0.0")?.isCompatible == true)
    precondition(SetupNodeVersion.parse("v21.99.99")?.isCompatible == false)
    for bad in ["22.18.0", "v22.18", "v22.18.0-rc.1", "v22..0", "", "node v22.18.0", "v22.18.0.1", "v-1.0.0", "v22.18.x"] { precondition(SetupNodeVersion.parse(bad) == nil, bad) }
    precondition(SetupNodeProbe.classify(exitStatus: 0, output: "v22.23.4\n") == .compatible(SetupNodeVersion(major: 22, minor: 23, patch: 4)))
    precondition(SetupNodeProbe.classify(exitStatus: 0, output: "v20.1.0") == .tooOld(SetupNodeVersion(major: 20, minor: 1, patch: 0)))
    precondition(SetupNodeProbe.classify(exitStatus: 1, output: "v22.23.4") == .notRunnable)
    precondition(SetupNodeProbe.classify(exitStatus: nil, output: "") == .notRunnable)
    precondition(SetupNodeProbe.classify(exitStatus: 0, output: "hello") == .unrecognized)

    // Path checks: files only, executable, absolute; folders and plain files are refused with distinct reasons.
    let kinds: [String: SetupFileKind] = ["/bin/node": .file(executable: true), "/etc/plain": .file(executable: false), "/opt": .directory]
    let kind: (String) -> SetupFileKind = { kinds[$0] ?? .missing }
    precondition(SetupPathIssue.check("", kind: kind) == .empty && SetupPathIssue.check("  \u{3000}", kind: kind) == .empty)
    precondition(SetupPathIssue.check("node", kind: kind) == .notAbsolute && SetupPathIssue.check("~/node", kind: kind) == .notAbsolute)
    precondition(SetupPathIssue.check("/nope", kind: kind) == .missing && SetupPathIssue.check("/opt", kind: kind) == .directory)
    precondition(SetupPathIssue.check("/etc/plain", kind: kind) == .notExecutable && SetupPathIssue.check("/bin/node", kind: kind) == nil)

    // Discovery ordering: PATH first, then brew, ~/.local/bin, then NVM newest-first; dups, folders, non-executables
    // and relative PATH entries never appear. NVM names that are not versions are ignored; ordering is numeric.
    let nvm = "/Users/me/.nvm/versions/node"
    let exec = SetupFileKind.file(executable: true)
    var files: [String: SetupFileKind] = [
        "/custom/bin/node": exec, "/opt/homebrew/bin/node": exec, "/usr/local/bin/node": .file(executable: false),
        "/Users/me/.local/bin/node": exec, "\(nvm)/v22.9.0/bin/node": exec, "\(nvm)/v22.23.4/bin/node": exec,
        "\(nvm)/v20.11.0/bin/node": exec, "\(nvm)/v22.18.0/bin/node": .directory, "rel/node": exec,
    ]
    let nodeEnv = fakeEnvironment(path: "/custom/bin:/opt/homebrew/bin:rel:/custom/bin::/missing", files: files,
                                  children: [nvm: ["v22.9.0", "v20.11.0", "default", "v22.23.4", "v22.18.0", "alias"]])
    precondition(SetupDiscovery.nodeCandidates(nodeEnv) == ["/custom/bin/node", "/opt/homebrew/bin/node", "/Users/me/.local/bin/node",
        "\(nvm)/v22.23.4/bin/node", "\(nvm)/v22.9.0/bin/node", "\(nvm)/v20.11.0/bin/node"])
    precondition(SetupDiscovery.nodeCandidates(fakeEnvironment(path: nil, files: [:])).isEmpty)
    files["/Users/me/.local/bin/omp"] = exec; files["/custom/bin/omp"] = exec; files["/Users/me/.bun/bin/omp"] = .directory
    precondition(SetupDiscovery.ompCandidates(fakeEnvironment(path: "/custom/bin", files: files)) == ["/custom/bin/omp", "/Users/me/.local/bin/omp"])
    precondition(SetupDiscovery.ompCandidates(fakeEnvironment(path: nil, files: files)) == ["/Users/me/.local/bin/omp"])
    let tooOld = SetupNodeProbe.tooOld(SetupNodeVersion(major: 20, minor: 0, patch: 0))
    let fine = SetupNodeProbe.compatible(SetupNodeVersion(major: 22, minor: 23, patch: 4))
    precondition(SetupDiscovery.preferredNode([("/a", .notRunnable), ("/b", tooOld), ("/c", fine), ("/d", fine)]) == "/c")
    precondition(SetupDiscovery.preferredNode([("/a", .notRunnable), ("/b", tooOld)]) == nil && SetupDiscovery.preferredNode([]) == nil)

    runSetupExistingConfigTests()
    runSetupDraftTests()
    runSetupProtocolTests()

    // Quit gate: quits pass through while idle; during a mutating install they are held and reported when it ends.
    var gate = SetupQuitGate()
    precondition(gate.quitAsked() == .terminateNow && gate.endMutation() == false)
    gate.beginMutation()
    precondition(gate.isMutating && gate.quitAsked() == .hold && gate.quitAsked() == .hold)
    precondition(gate.endMutation() == true && !gate.isMutating && gate.quitAsked() == .terminateNow)
    gate.beginMutation()
    precondition(gate.endMutation() == false, "no quit was requested")

    // Child PATH: configured Node and omp directories first, inherited entries kept in order, no duplicates or empties.
    precondition(ChildEnvironment.path(nodePath: "/n/bin/node", ompPath: "/o/bin/omp", basePath: "/usr/bin:/n/bin::/bin") == "/n/bin:/o/bin:/usr/bin:/bin")
    precondition(ChildEnvironment.path(nodePath: "/n/bin/node", ompPath: "/n/bin/omp", basePath: nil) == "/n/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    precondition(ChildEnvironment.path(nodePath: "", ompPath: "relative/omp", basePath: "") == ChildEnvironment.fallbackPath)
    let environment = ChildEnvironment.environment(base: ["PATH": "/bin", "HOME": "/h", "KEEP": "1"], nodePath: "/n/node", ompPath: "/o/omp")
    precondition(environment == ["PATH": "/n:/o:/bin", "HOME": "/h", "KEEP": "1"])
}

private func runSetupExistingConfigTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omp-setup-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("config.json").path

    precondition(SetupExistingConfig.read(path: path) == .none, "a missing file is a fresh install")
    precondition(!FileManager.default.fileExists(atPath: path), "reading never creates the file")

    // Valid: read-only values, bytes untouched (an odd but valid layout survives byte for byte).
    let original = Data((validConfigJSON + "\n\n").utf8)
    try! original.write(to: URL(fileURLWithPath: path))
    guard case .valid(let config) = SetupExistingConfig.read(path: path) else { preconditionFailure("valid config must be read") }
    precondition(config.nodePath == "/opt/n/bin/node" && config.ompPath == "/opt/o/bin/omp" && config.profile == "work")
    precondition(try! Data(contentsOf: URL(fileURLWithPath: path)) == original, "setup never rewrites an existing config")

    // Malformed, schema-invalid and unreadable states are refused with a controlled message, never treated as none.
    for bad in ["not json", "{}", validConfigJSON.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), ""] {
        try! Data(bad.utf8).write(to: URL(fileURLWithPath: path))
        guard case .refused(let message) = SetupExistingConfig.read(path: path) else { preconditionFailure("must refuse: \(bad)") }
        precondition(!message.isEmpty && !message.contains("not json"), "messages never echo content")
    }
    try! FileManager.default.removeItem(atPath: path)
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    guard case .refused = SetupExistingConfig.read(path: path) else { preconditionFailure("a directory at the config path must be refused") }
    try! FileManager.default.removeItem(atPath: path)
    try! FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: directory.appendingPathComponent("gone.json").path)
    guard case .refused = SetupExistingConfig.read(path: path) else { preconditionFailure("a dangling symlink must be refused, not reset") }
}

private func runSetupDraftTests() {
    let exec = SetupFileKind.file(executable: true)
    let files: [String: SetupFileKind] = ["/n/bin/node": exec, "/o/bin/omp": exec, "/d": .directory, "/opt/n/bin/node": exec]
    let kind: (String) -> SetupFileKind = { files[$0] ?? .missing }
    let compatible = SetupNodeProbe.compatible(SetupNodeVersion(major: 22, minor: 23, patch: 4))

    // Fresh install: suggestions only, defaults visible, ready only after a compatible probe of the CURRENT path.
    var draft = SetupDraft(existing: .none, suggestedNode: "/n/bin/node", suggestedOmp: "/o/bin/omp")
    precondition(draft.profile == "default" && !draft.isReadOnly && !draft.isRefused && !draft.isDirty)
    precondition(draft.blocker(kind: kind) == .nodeProbing && draft.request(sourceAppPath: "/s", hostPid: 7, kind: kind) == nil)
    draft.record(nodeProbe: compatible, for: "/elsewhere")
    precondition(draft.blocker(kind: kind) == .nodeProbing, "a probe for another path is ignored")
    draft.record(nodeProbe: compatible, for: "/n/bin/node")
    precondition(draft.canInstall(kind: kind) && !draft.isDirty, "accepting the suggestions is not an edit")
    precondition(draft.request(sourceAppPath: "/s/OMP Usage.app", hostPid: 7, kind: kind) == SetupRequest(sourceAppPath: "/s/OMP Usage.app", hostPid: 7, nodePath: "/n/bin/node", ompPath: "/o/bin/omp", profile: "default"))

    // Editing invalidates the probe and the verdict follows the field, not a stale measurement.
    draft.setNodePath("/opt/n/bin/node")
    precondition(draft.isDirty && draft.currentNodeProbe == nil && draft.blocker(kind: kind) == .nodeProbing)
    draft.record(nodeProbe: SetupNodeProbe.tooOld(SetupNodeVersion(major: 20, minor: 0, patch: 0)), for: "/opt/n/bin/node")
    precondition(draft.blocker(kind: kind) == .nodeTooOld(SetupNodeVersion(major: 20, minor: 0, patch: 0)))
    draft.setNodePath("/d"); precondition(draft.blocker(kind: kind) == .node(.directory))
    draft.setNodePath(""); precondition(draft.blocker(kind: kind) == .node(.empty))
    draft.setNodePath("/n/bin/node"); draft.record(nodeProbe: compatible, for: "/n/bin/node")
    draft.setOmpPath("/d"); precondition(draft.blocker(kind: kind) == .omp(.directory))
    draft.setOmpPath("/missing"); precondition(draft.blocker(kind: kind) == .omp(.missing))
    draft.setOmpPath("/o/bin/omp"); draft.setProfile(" \t"); precondition(draft.blocker(kind: kind) == .profile)
    draft.setProfile("  work "); precondition(draft.canInstall(kind: kind))
    precondition(draft.request(sourceAppPath: "/s", hostPid: 1, kind: kind)?.profile == "  work ", "values are sent verbatim, never normalized")
    precondition(draft.blockerMessage(.nodeProbing).contains("Node") && draft.blockerMessage(.nodeTooOld(SetupNodeVersion.minimum)).contains("22.18"))
    var restored = draft
    restored.setNodePath("/n/bin/node"); restored.setOmpPath("/o/bin/omp"); restored.setProfile("default")
    precondition(!restored.isDirty, "returning to the shown values is clean")

    // Valid existing config: authoritative and read-only, and the request carries no overriding values.
    let json = validConfigJSON.data(using: .utf8)!
    let config = try! PanelConfigStore.decode(json)
    var existing = SetupDraft(existing: .valid(config), suggestedNode: "/n/bin/node", suggestedOmp: "/o/bin/omp")
    precondition(existing.isReadOnly && existing.nodePath == "/opt/n/bin/node" && existing.ompPath == "/opt/o/bin/omp" && existing.profile == "work")
    existing.setNodePath("/n/bin/node"); existing.setOmpPath("/x"); existing.setProfile("changed")
    precondition(existing.nodePath == "/opt/n/bin/node" && existing.ompPath == "/opt/o/bin/omp" && existing.profile == "work" && !existing.isDirty)
    precondition(existing.blocker(kind: kind) == .nodeProbing)
    existing.record(nodeProbe: compatible, for: "/opt/n/bin/node")
    precondition(existing.canInstall(kind: { files[$0] ?? .missing }), "only the helper's Node must be usable")
    precondition(existing.canInstall(kind: { $0 == "/opt/n/bin/node" ? exec : .missing }), "a missing omp does not block an existing authoritative config")
    precondition(existing.request(sourceAppPath: "/s", hostPid: 9, kind: kind) == SetupRequest(sourceAppPath: "/s", hostPid: 9, nodePath: nil, ompPath: nil, profile: nil))
    precondition(existing.helperNodePath == "/opt/n/bin/node")

    // Refused config: install stays blocked with the controlled reason; nothing can unblock it from the form.
    var refused = SetupDraft(existing: .refused("Invalid panel configuration: version must be 1."), suggestedNode: "/n/bin/node", suggestedOmp: "/o/bin/omp")
    precondition(refused.isRefused && refused.blocker(kind: kind) == .refusedConfig && !refused.canInstall(kind: kind))
    refused.record(nodeProbe: compatible, for: "/n/bin/node")
    refused.setNodePath("/n/bin/node")
    precondition(refused.blocker(kind: kind) == .refusedConfig && refused.request(sourceAppPath: "/s", hostPid: 1, kind: kind) == nil)
    precondition(refused.blockerMessage(.refusedConfig).contains("version must be 1"))

    // No Node at all: the form still works, install is blocked by the empty Node path, and an omp suggestion is kept.
    let none = SetupDraft(existing: .none, suggestedNode: "", suggestedOmp: "/o/bin/omp")
    precondition(none.blocker(kind: kind) == .node(.empty) && none.ompPath == "/o/bin/omp")
}

private func runSetupProtocolTests() {
    // Request: only accepted keys, none for nil optionals, stable order.
    let full = SetupRequest(sourceAppPath: "/Volumes/OMP Usage/OMP Usage.app", hostPid: 42, nodePath: "/n/node", ompPath: "/o/omp", profile: "default")
    precondition(String(decoding: try! full.encoded(), as: UTF8.self) == #"{"hostPid":42,"nodePath":"/n/node","ompPath":"/o/omp","profile":"default","sourceAppPath":"/Volumes/OMP Usage/OMP Usage.app"}"#)
    let bare = SetupRequest(sourceAppPath: "/a", hostPid: 1, nodePath: nil, ompPath: nil, profile: nil)
    precondition(String(decoding: try! bare.encoded(), as: UTF8.self) == #"{"hostPid":1,"sourceAppPath":"/a"}"#)

    func parse(_ json: String, status: Int32 = 0, command: SetupCommand = .install) -> Result<SetupSuccess, SetupFailure> {
        SetupResponse.parse(stdout: Data(json.utf8), exitStatus: status, command: command)
    }
    let ok = #"{"ok":true,"command":"install","action":"relaunch","appPath":"/Users/me/Applications/OMP Usage.app","configPath":"/Users/me/Library/Application Support/omp-usage-panel/config.json"}"# + "\n"
    precondition(parse(ok) == .success(SetupSuccess(command: .install, action: .relaunch, appPath: "/Users/me/Applications/OMP Usage.app", configPath: "/Users/me/Library/Application Support/omp-usage-panel/config.json", pid: nil)))
    let activate = #"{"ok":true,"command":"launch","action":"activate","appPath":"/a","configPath":"/c","pid":321}"#
    precondition(parse(activate, command: .launch) == .success(SetupSuccess(command: .launch, action: .activate, appPath: "/a", configPath: "/c", pid: 321)))
    let invalid = SetupFailure(code: "invalid-response")
    precondition(parse(activate, command: .install) == .failure(invalid), "command echo must match")
    precondition(parse(#"{"ok":true,"command":"launch","action":"activate","appPath":"/a","configPath":"/c"}"#, command: .launch) == .failure(invalid), "activate needs a pid")
    precondition(parse(#"{"ok":true,"command":"launch","action":"continue","appPath":"/a","configPath":"/c","pid":0}"#, command: .launch) == .failure(invalid))
    precondition(parse(ok, status: 1) == .failure(invalid), "success JSON with a failing exit is not trusted")
    precondition(parse(#"{"ok":true,"command":"install","action":"explode","appPath":"/a","configPath":"/c"}"#) == .failure(invalid))
    precondition(parse(#"{"ok":true,"command":"install","action":"relaunch","appPath":"rel","configPath":"/c"}"#) == .failure(invalid))
    precondition(parse("garbage") == .failure(invalid) && parse("") == .failure(invalid) && parse("[]") == .failure(invalid))
    precondition(parse(#"{"ok":false,"command":"install"}"#, status: 1) == .failure(invalid))
    precondition(parse(#"{"ok":false,"command":"install","error":{"code":"running","message":"secret /Users/me stderr"}}"#, status: 1) == .failure(SetupFailure(code: "running")))
    precondition(parse(#"{"ok":false,"command":"install","error":{"code":"Bad Code\nrm -rf","message":"x"}}"#, status: 1) == .failure(SetupFailure(code: "failed")), "unprintable codes are replaced")
    precondition(SetupResponse.sanitizedCode("a-b_c9") == "a-b_c9" && SetupResponse.sanitizedCode("") == "failed" && SetupResponse.sanitizedCode(String(repeating: "a", count: 41)) == "failed")
}
