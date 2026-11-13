import Foundation

private func fakeEnvironment(home: String = "/Users/me", path: String?, files: [String: SetupFileKind]) -> SetupDiscoveryEnvironment {
    SetupDiscoveryEnvironment(home: home, path: path, kind: { files[$0] ?? .missing })
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


    // Path checks: files only, executable, absolute; folders and plain files are refused with distinct reasons.
    let kinds: [String: SetupFileKind] = ["/bin/node": .file(executable: true), "/etc/plain": .file(executable: false), "/opt": .directory]
    let kind: (String) -> SetupFileKind = { kinds[$0] ?? .missing }
    precondition(SetupPathIssue.check("", kind: kind) == .empty && SetupPathIssue.check("  \u{3000}", kind: kind) == .empty)
    precondition(SetupPathIssue.check("node", kind: kind) == .notAbsolute && SetupPathIssue.check("~/node", kind: kind) == .notAbsolute)
    precondition(SetupPathIssue.check("/nope", kind: kind) == .missing && SetupPathIssue.check("/opt", kind: kind) == .directory)
    precondition(SetupPathIssue.check("/etc/plain", kind: kind) == .notExecutable && SetupPathIssue.check("/bin/node", kind: kind) == nil)

    // omp discovery ordering: PATH first, then ~/.local/bin, ~/.bun/bin, Homebrew; dups, folders, non-executables
    // and relative PATH entries never appear.
    let exec = SetupFileKind.file(executable: true)
    var files: [String: SetupFileKind] = [:]
    files["/Users/me/.local/bin/omp"] = exec; files["/custom/bin/omp"] = exec; files["/Users/me/.bun/bin/omp"] = .directory; files["rel/omp"] = exec
    precondition(SetupDiscovery.ompCandidates(fakeEnvironment(path: "/custom/bin:rel:/custom/bin::/missing", files: files)) == ["/custom/bin/omp", "/Users/me/.local/bin/omp"])
    precondition(SetupDiscovery.ompCandidates(fakeEnvironment(path: nil, files: files)) == ["/Users/me/.local/bin/omp"])

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

    // Child PATH: the Node and omp directories first, inherited entries kept in order, no duplicates or empties.
    // The Node directory is the config's while it exists; a dangling one (pruned managed runtime) falls back to the managed Node.
    let managed = "/Users/me/Library/Application Support/omp-usage-panel/runtime/node-9.9.9-arm64/node"
    let live: (String) -> Bool = { $0 == "/opt/n/bin" || $0 == "/Users/me/Library/Application Support/omp-usage-panel/runtime/node-9.9.9-arm64" }
    precondition(ChildEnvironment.pathNode(configured: "/opt/n/bin/node", managed: managed, directoryExists: live) == "/opt/n/bin/node", "legacy Node directory that exists keeps today's PATH")
    precondition(ChildEnvironment.pathNode(configured: "/gone/runtime/node-9.0.0-arm64/node", managed: managed, directoryExists: live) == managed, "dangling Node directory falls back to the managed one")
    precondition(ChildEnvironment.pathNode(configured: "relative/node", managed: managed, directoryExists: { _ in true }) == managed)
    precondition(ChildEnvironment.path(nodePath: ChildEnvironment.pathNode(configured: "/opt/n/bin/node", managed: managed, directoryExists: live), ompPath: "/o/bin/omp", basePath: "/usr/bin") == "/opt/n/bin:/o/bin:/usr/bin")
    precondition(ChildEnvironment.path(nodePath: ChildEnvironment.pathNode(configured: "/gone/node", managed: managed, directoryExists: live), ompPath: "/o/bin/omp", basePath: "/usr/bin") == "/Users/me/Library/Application Support/omp-usage-panel/runtime/node-9.9.9-arm64:/o/bin:/usr/bin")
    precondition(ChildEnvironment.path(nodePath: ChildEnvironment.pathNode(configured: managed, managed: managed, directoryExists: live), ompPath: "/o/bin/omp", basePath: "/usr/bin") == "/Users/me/Library/Application Support/omp-usage-panel/runtime/node-9.9.9-arm64:/o/bin:/usr/bin", "identical configured and managed directories appear once")
    precondition(ChildEnvironment.directoryExists("/") && !ChildEnvironment.directoryExists("/definitely/not/here") && !ChildEnvironment.directoryExists("/etc/hosts"))
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
    let files: [String: SetupFileKind] = ["/o/bin/omp": exec, "/d": .directory]
    let kind: (String) -> SetupFileKind = { files[$0] ?? .missing }

    // Fresh install: suggestions only, defaults visible; ready as soon as omp and the profile are usable (no Node step).
    var draft = SetupDraft(existing: .none, suggestedOmp: "/o/bin/omp")
    precondition(draft.profile == "default" && !draft.isReadOnly && !draft.isRefused && !draft.isDirty)
    precondition(draft.canInstall(kind: kind) && !draft.isDirty, "accepting the suggestions is not an edit")
    precondition(draft.request(sourceAppPath: "/s/OMP Usage.app", hostPid: 7, kind: kind) == SetupRequest(sourceAppPath: "/s/OMP Usage.app", hostPid: 7, ompPath: "/o/bin/omp", profile: "default"))

    // Editing follows the field, not a stale measurement.
    draft.setOmpPath("/d"); precondition(draft.isDirty && draft.blocker(kind: kind) == .omp(.directory))
    draft.setOmpPath("/missing"); precondition(draft.blocker(kind: kind) == .omp(.missing))
    draft.setOmpPath(""); precondition(draft.blocker(kind: kind) == .omp(.empty))
    draft.setOmpPath("/o/bin/omp"); draft.setProfile(" \t"); precondition(draft.blocker(kind: kind) == .profile)
    draft.setProfile("  work "); precondition(draft.canInstall(kind: kind))
    precondition(draft.request(sourceAppPath: "/s", hostPid: 1, kind: kind)?.profile == "  work ", "values are sent verbatim, never normalized")
    var restored = draft
    restored.setOmpPath("/o/bin/omp"); restored.setProfile("default")
    precondition(!restored.isDirty, "returning to the shown values is clean")

    // Valid existing config: authoritative and read-only, not blocked by anything (the legacy Node path is never probed),
    // and the request carries no overriding values.
    let config = try! PanelConfigStore.decode(validConfigJSON.data(using: .utf8)!)
    var existing = SetupDraft(existing: .valid(config), suggestedOmp: "/o/bin/omp")
    precondition(existing.isReadOnly && existing.ompPath == "/opt/o/bin/omp" && existing.profile == "work")
    existing.setOmpPath("/x"); existing.setProfile("changed")
    precondition(existing.ompPath == "/opt/o/bin/omp" && existing.profile == "work" && !existing.isDirty)
    precondition(existing.blocker(kind: { _ in .missing }) == nil, "a missing omp or Node path does not block an existing authoritative config")
    precondition(existing.request(sourceAppPath: "/s", hostPid: 9, kind: { _ in .missing }) == SetupRequest(sourceAppPath: "/s", hostPid: 9, ompPath: nil, profile: nil))

    // Refused config: install stays blocked with the controlled reason; nothing can unblock it from the form.
    var refused = SetupDraft(existing: .refused("Invalid panel configuration: version must be 1."), suggestedOmp: "/o/bin/omp")
    precondition(refused.isRefused && refused.blocker(kind: kind) == .refusedConfig && !refused.canInstall(kind: kind))
    refused.setOmpPath("/o/bin/omp")
    precondition(refused.blocker(kind: kind) == .refusedConfig && refused.request(sourceAppPath: "/s", hostPid: 1, kind: kind) == nil)
    precondition(refused.blockerMessage(.refusedConfig).contains("version must be 1"))

    // No omp found: the form still works and install is blocked by the empty omp path.
    let none = SetupDraft(existing: .none, suggestedOmp: "")
    precondition(none.blocker(kind: kind) == .omp(.empty))

    // App-originated node failures carry their own controlled text; the code alone gets generic bundled-runtime wording.
    precondition(SetupFailure(code: "node-unavailable").userMessage.contains("bundled Node.js"))
    precondition(SetupFailure(code: "node-unavailable", detail: ManagedNodeError.archiveMismatch.userMessage).userMessage == ManagedNodeError.archiveMismatch.userMessage)
}

private func runSetupProtocolTests() {
    // Request: only accepted keys, none for nil optionals, stable order.
    let full = SetupRequest(sourceAppPath: "/Volumes/OMP Usage/OMP Usage.app", hostPid: 42, ompPath: "/o/omp", profile: "default")
    precondition(String(decoding: try! full.encoded(), as: UTF8.self) == #"{"hostPid":42,"ompPath":"/o/omp","profile":"default","sourceAppPath":"/Volumes/OMP Usage/OMP Usage.app"}"#)
    let bare = SetupRequest(sourceAppPath: "/a", hostPid: 1, ompPath: nil, profile: nil)
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
