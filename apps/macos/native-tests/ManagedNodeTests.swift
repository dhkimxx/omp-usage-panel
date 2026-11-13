import Foundation
import CryptoKit

private func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private let sha = String(repeating: "a", count: 64)

private func manifestJSON(mutating change: (inout [String: Any]) -> Void = { _ in }) -> Data {
    let entry: [String: Any] = ["archive": "node-arm64.tar.xz", "archiveSize": 10, "archiveSHA256": sha, "binarySize": 20, "binarySHA256": sha]
    var root: [String: Any] = ["schema": 1, "version": "22.23.5", "teamIdentifier": "HX7739G8FX", "arches": ["arm64": entry]]
    change(&root)
    return try! JSONSerialization.data(withJSONObject: root)
}

func runManagedNodeTests() {
    // Manifest: strict keys, canonical names and digests; booleans, floats and extra keys are refused.
    let manifest = try! ManagedNodeManifest.parse(manifestJSON())
    precondition(manifest.version == "22.23.5" && manifest.teamIdentifier == "HX7739G8FX" && manifest.arches["arm64"]?.binarySize == 20 && manifest.arches["x64"] == nil)
    func rejects(_ change: (inout [String: Any]) -> Void, _ message: String) {
        do { _ = try ManagedNodeManifest.parse(manifestJSON(mutating: change)); preconditionFailure("must reject: \(message)") }
        catch { precondition(error as? ManagedNodeError == .manifestInvalid, message) }
    }
    func entryChange(_ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { root in
            var arches = root["arches"] as! [String: Any]
            var entry = arches["arm64"] as! [String: Any]
            edit(&entry); arches["arm64"] = entry; root["arches"] = arches
        }
    }
    rejects({ $0["schema"] = 2 }, "schema")
    rejects({ $0["schema"] = true }, "boolean schema")
    rejects({ $0["extra"] = 1 }, "extra root key")
    rejects({ $0["version"] = "22.23" }, "version shape")
    rejects({ $0["teamIdentifier"] = "short" }, "team shape")
    rejects({ $0["version"] = "22.23.5\n" }, "version trailing newline")
    rejects({ $0["teamIdentifier"] = "ABCDE12345\n" }, "team trailing newline")
    rejects(entryChange { $0["binarySHA256"] = sha + "\n" }, "digest trailing newline")
    rejects({ $0["arches"] = [String: Any]() }, "no arches")
    rejects({ root in
        let entry = (root["arches"] as! [String: Any])["arm64"]!
        root["arches"] = ["arm64": entry, "ppc": entry]
    }, "unknown arch")
    rejects(entryChange { $0["archive"] = "../node-arm64.tar.xz" }, "archive name")
    rejects(entryChange { $0["archiveSize"] = 0 }, "zero size")
    rejects(entryChange { $0["binarySize"] = 1.5 }, "fractional size")
    rejects(entryChange { $0["binarySHA256"] = String(repeating: "A", count: 64) }, "uppercase digest")
    rejects(entryChange { $0["archiveSHA256"] = "abc" }, "short digest")
    rejects(entryChange { $0["extra"] = true }, "extra entry key")
    precondition((try? ManagedNodeManifest.parse(Data("[]".utf8))) == nil && (try? ManagedNodeManifest.parse(Data())) == nil)

    // Architecture: Apple-silicon hardware picks arm64 (even for a Rosetta slice); a manifest lacking it is an error.
    let both = ManagedNodeManifest(version: "1.0.0", teamIdentifier: "ABCDE12345", arches: ["arm64": manifest.arches["arm64"]!, "x64": manifest.arches["arm64"]!])
    precondition(try! ManagedNodeLogic.chooseArch(arm64Capable: true, manifest: both) == "arm64")
    precondition(try! ManagedNodeLogic.chooseArch(arm64Capable: false, manifest: both) == "x64")
    do { _ = try ManagedNodeLogic.chooseArch(arm64Capable: false, manifest: manifest); preconditionFailure("x64 is not in the manifest") }
    catch { precondition(error as? ManagedNodeError == .archUnavailable("x64")) }
    let x64Only = ManagedNodeManifest(version: "1.0.0", teamIdentifier: "ABCDE12345", arches: ["x64": manifest.arches["arm64"]!])
    precondition(try! ManagedNodeLogic.chooseArch(arm64Capable: true, manifest: x64Only) == "x64", "arm64 hardware runs an x64-only bundle under Rosetta")

    // Paths and messages: the runtime lives under the support directory; user text names the bundled runtime only.
    precondition(ManagedNodeLogic.supportDirectory(home: "/Users/me") == "/Users/me/Library/Application Support/omp-usage-panel")
    precondition(ManagedNodeLogic.directoryName(version: "22.23.5", arch: "arm64") == "node-22.23.5-arm64")
    precondition(ManagedNodeLogic.transactionPath(support: "/s") == "/s/updater/transaction" && ManagedNodeLogic.runtimeDirectory(support: "/s") == "/s/runtime")
    for error in [ManagedNodeError.manifestMissing, .manifestInvalid, .archUnavailable("x64"), .archiveMissing, .archiveMismatch, .extractionFailed, .contentsInvalid, .binaryMismatch, .signatureInvalid, .quarantined, .ioError("x")] {
        precondition(error.userMessage.contains("Node.js") && !error.userMessage.contains("/"), "\(error)")
    }

    // Marker fast path: exact marker, regular executable node of the verified size.
    let marker = ManagedNodeMarker(manifest: manifest, arch: "arm64", entry: manifest.arches["arm64"]!)
    let markerData = try! marker.encoded()
    let good = ManagedNodeFileInfo(isRegular: true, isExecutable: true, size: 20)
    precondition(ManagedNodeLogic.isComplete(markerData: markerData, expected: marker, node: good))
    precondition(!ManagedNodeLogic.isComplete(markerData: nil, expected: marker, node: good))
    precondition(!ManagedNodeLogic.isComplete(markerData: Data("{}".utf8), expected: marker, node: good))
    precondition(!ManagedNodeLogic.isComplete(markerData: markerData, expected: marker, node: nil))
    precondition(!ManagedNodeLogic.isComplete(markerData: markerData, expected: marker, node: ManagedNodeFileInfo(isRegular: true, isExecutable: false, size: 20)))
    precondition(!ManagedNodeLogic.isComplete(markerData: markerData, expected: marker, node: ManagedNodeFileInfo(isRegular: true, isExecutable: true, size: 19)))
    precondition(!ManagedNodeLogic.isComplete(markerData: markerData, expected: marker, node: ManagedNodeFileInfo(isRegular: false, isExecutable: true, size: 20)))
    // The marker identifies the Node binary, not the archive: a repacked archive of the same binary keeps the runtime.
    let repacked = ManagedNodeArchive(archive: "node-arm64.tar.xz", archiveSize: 99, archiveSHA256: String(repeating: "b", count: 64), binarySize: 20, binarySHA256: sha)
    precondition(ManagedNodeLogic.isComplete(markerData: markerData, expected: ManagedNodeMarker(manifest: manifest, arch: "arm64", entry: repacked), node: good), "archive hash is not part of the marker")
    let otherBinary = ManagedNodeArchive(archive: "node-arm64.tar.xz", archiveSize: 10, archiveSHA256: sha, binarySize: 20, binarySHA256: String(repeating: "b", count: 64))
    precondition(!ManagedNodeLogic.isComplete(markerData: markerData, expected: ManagedNodeMarker(manifest: manifest, arch: "arm64", entry: otherBinary), node: good), "a marker for a different binary is stale")
    precondition(!String(decoding: markerData, as: UTF8.self).contains("archiveSHA256"))

    // Pruning: only other node-* directories, and never while an update transaction exists.
    let entries = ["node-22.23.5-arm64", "node-22.0.0-arm64", "node-21.0.0-x64", ".lock", "keep", ".extract-1"]
    precondition(ManagedNodeLogic.prunable(entries: entries, current: "node-22.23.5-arm64", transactionExists: false) == ["node-21.0.0-x64", "node-22.0.0-arm64"])
    precondition(ManagedNodeLogic.prunable(entries: entries, current: "node-22.23.5-arm64", transactionExists: true).isEmpty)
    precondition(ManagedNodeLogic.staleExtractions(entries: entries) == [".extract-1"])

    // Code-signing output parsing.
    precondition(ManagedNodeLogic.teamIdentifier(fromCodesignOutput: "Identifier=node\nTeamIdentifier=HX7739G8FX\nSealed Resources=none\n") == "HX7739G8FX")
    precondition(ManagedNodeLogic.teamIdentifier(fromCodesignOutput: "Identifier=node\nTeamIdentifier=not set\n") == "not set")
    precondition(ManagedNodeLogic.teamIdentifier(fromCodesignOutput: "Identifier=node\n") == nil)

    runManagedNodeProvisioningTests()
}

/// Real extraction with a stubbed code-signing check: the published tree, fast path, repair, pruning and concurrency.
private func runManagedNodeProvisioningTests() {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("omp-managed-node-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }
    func make(_ path: String) -> String { try! fileManager.createDirectory(atPath: path, withIntermediateDirectories: true); return path }

    let content = root.appendingPathComponent("content").path
    _ = make(content)
    let nodeBytes = Data("#!/bin/sh\necho v22.23.5\n".utf8)
    try! nodeBytes.write(to: URL(fileURLWithPath: content + "/node"))
    try! Data("license".utf8).write(to: URL(fileURLWithPath: content + "/LICENSE"))
    let resources = make(root.appendingPathComponent("Resources/node").path)
    let archive = resources + "/node-x64.tar.xz"
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-cJf", archive, "-C", content, "node", "LICENSE"]
    tar.environment = ["COPYFILE_DISABLE": "1"]
    try! tar.run(); tar.waitUntilExit()
    precondition(tar.terminationStatus == 0, "fixture archive")
    let archiveData = try! Data(contentsOf: URL(fileURLWithPath: archive))
    let manifestObject: [String: Any] = [
        "schema": 1, "version": "9.9.9", "teamIdentifier": "ABCDE12345",
        "arches": ["x64": ["archive": "node-x64.tar.xz", "archiveSize": archiveData.count, "archiveSHA256": sha256Hex(archiveData),
                           "binarySize": nodeBytes.count, "binarySHA256": sha256Hex(nodeBytes)]],
    ]
    try! JSONSerialization.data(withJSONObject: manifestObject).write(to: URL(fileURLWithPath: resources + "/manifest.json"))

    var environment = ManagedNode.Environment()
    environment.arm64Capable = { false }
    environment.signingTeam = { _ in .success("ABCDE12345") }

    let home = make(root.appendingPathComponent("home").path)
    let support = ManagedNodeLogic.supportDirectory(home: home)
    let runtime = support + "/runtime"
    let expected = runtime + "/node-9.9.9-x64/node"

    // Stale siblings: a superseded runtime and an abandoned extraction are cleaned only after a successful install.
    _ = make(runtime + "/node-9.0.0-x64"); _ = make(runtime + "/.extract-abandoned")
    switch ManagedNode.ensure(resources: resources, home: home, environment: environment) {
    case .success(let path): precondition(path == expected, "managed path")
    case .failure(let error): preconditionFailure("first ensure failed: \(error)")
    }
    precondition(fileManager.isExecutableFile(atPath: expected) && (try! Data(contentsOf: URL(fileURLWithPath: expected))) == nodeBytes)
    precondition(fileManager.fileExists(atPath: runtime + "/node-9.9.9-x64/complete.json") && fileManager.fileExists(atPath: runtime + "/node-9.9.9-x64/LICENSE"))
    precondition(!fileManager.fileExists(atPath: runtime + "/node-9.0.0-x64") && !fileManager.fileExists(atPath: runtime + "/.extract-abandoned"), "superseded and abandoned directories pruned")
    precondition(((try? fileManager.contentsOfDirectory(atPath: runtime)) ?? []).filter { $0.hasPrefix(".extract-") }.isEmpty, "no staging left behind")
    let excluded = try? URL(fileURLWithPath: runtime).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    precondition(excluded == true, "runtime directory is excluded from backups")

    // Fast path never touches the bundle: it works with the archive and manifest gone.
    try! fileManager.removeItem(atPath: archive)
    guard case .success(expected) = ManagedNode.ensure(resources: resources, home: home, environment: environment) else { preconditionFailure("fast path must not need the archive") }

    // A damaged runtime (wrong size) is repaired from the archive; with the archive gone that is a typed failure.
    try! Data("broken".utf8).write(to: URL(fileURLWithPath: expected))
    precondition(ManagedNode.ensure(resources: resources, home: home, environment: environment) == .failure(.archiveMissing))
    try! archiveData.write(to: URL(fileURLWithPath: archive))
    guard case .success(expected) = ManagedNode.ensure(resources: resources, home: home, environment: environment) else { preconditionFailure("repair must succeed") }
    precondition((try! Data(contentsOf: URL(fileURLWithPath: expected))) == nodeBytes, "repaired binary")

    // A tampered archive, and a wrong Team ID, never publish anything.
    let fresh = make(root.appendingPathComponent("fresh").path)
    var tampered = archiveData; tampered[tampered.count / 2] ^= 0xFF
    try! tampered.write(to: URL(fileURLWithPath: archive))
    precondition(ManagedNode.ensure(resources: resources, home: fresh, environment: environment) == .failure(.archiveMismatch))
    try! archiveData.write(to: URL(fileURLWithPath: archive))
    var wrongTeam = environment
    wrongTeam.signingTeam = { _ in .success("ZZZZZZZZZZ") }
    precondition(ManagedNode.ensure(resources: resources, home: fresh, environment: wrongTeam) == .failure(.signatureInvalid))
    let freshRuntime = ManagedNodeLogic.runtimeDirectory(support: ManagedNodeLogic.supportDirectory(home: fresh))
    let leftovers = ((try? fileManager.contentsOfDirectory(atPath: freshRuntime)) ?? []).filter { $0.hasPrefix("node-") || $0.hasPrefix(".extract-") }
    precondition(leftovers.isEmpty, "failed installs leave no node directory or staging behind: \(leftovers)")

    // Regression: a DMG-installed app's archives carry com.apple.quarantine, and `tar -xJf <path>` copies it onto every
    // extracted file (a quarantined unnotarized node is killed on exec). Extraction must not inherit it. The archive
    // keeps the attribute for every later scenario in this function.
    func hasQuarantine(_ path: String) -> Bool { getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    let quarantineValue = Array("0081;6af00000;Safari;\(UUID().uuidString)".utf8)
    precondition(setxattr(archive, "com.apple.quarantine", quarantineValue, quarantineValue.count, 0, 0) == 0 && hasQuarantine(archive), "fixture archive is quarantined")
    let quarantined = make(root.appendingPathComponent("quarantined").path)
    let quarantinedNode = ManagedNodeLogic.runtimeDirectory(support: ManagedNodeLogic.supportDirectory(home: quarantined)) + "/node-9.9.9-x64/node"
    guard case .success(quarantinedNode) = ManagedNode.ensure(resources: resources, home: quarantined, environment: environment) else { preconditionFailure("a quarantined archive must still extract cleanly") }
    precondition(!hasQuarantine(quarantinedNode) && !hasQuarantine(quarantinedNode.replacingOccurrences(of: "/node", with: "/LICENSE")), "extracted files must not inherit the archive's quarantine")
    try! fileManager.moveItem(atPath: archive, toPath: archive + ".gone")
    guard case .success(quarantinedNode) = ManagedNode.ensure(resources: resources, home: quarantined, environment: environment) else { preconditionFailure("fast path after a quarantined extraction") }
    try! fileManager.moveItem(atPath: archive + ".gone", toPath: archive)

    // An in-flight update transaction keeps older runtimes (a rollback may still need them).
    let transactional = make(root.appendingPathComponent("transactional").path)
    let transactionalSupport = ManagedNodeLogic.supportDirectory(home: transactional)
    _ = make(transactionalSupport + "/updater/transaction"); _ = make(transactionalSupport + "/runtime/node-9.0.0-x64")
    guard case .success = ManagedNode.ensure(resources: resources, home: transactional, environment: environment) else { preconditionFailure("transactional ensure") }
    precondition(fileManager.fileExists(atPath: transactionalSupport + "/runtime/node-9.0.0-x64"), "kept while a transaction exists")

    // Concurrent first runs (app start plus Setup) converge on one intact runtime.
    let racing = make(root.appendingPathComponent("racing").path)
    let group = DispatchGroup()
    let lock = NSLock()
    var results: [Result<String, ManagedNodeError>] = []
    for _ in 0..<6 {
        group.enter()
        DispatchQueue.global().async {
            let result = ManagedNode.ensure(resources: resources, home: racing, environment: environment)
            lock.lock(); results.append(result); lock.unlock()
            group.leave()
        }
    }
    group.wait()
    let racingExpected = ManagedNodeLogic.runtimeDirectory(support: ManagedNodeLogic.supportDirectory(home: racing)) + "/node-9.9.9-x64/node"
    precondition(results.count == 6 && results.allSatisfy { $0 == .success(racingExpected) }, "all concurrent callers get the same path: \(results)")
    precondition((try! Data(contentsOf: URL(fileURLWithPath: racingExpected))) == nodeBytes)

    // Superseded runtimes survive while an update transaction exists (the first ensure after an update sees it) and are
    // pruned by a LATER fast-path ensure once it is gone. The current directory and symlinks are never removed.
    let pruneHome = make(root.appendingPathComponent("prune").path)
    let pruneSupport = ManagedNodeLogic.supportDirectory(home: pruneHome)
    let pruneRuntime = pruneSupport + "/runtime"
    let pruneExpected = pruneRuntime + "/node-9.9.9-x64/node"
    guard case .success(pruneExpected) = ManagedNode.ensure(resources: resources, home: pruneHome, environment: environment) else { preconditionFailure("prune fixture install") }
    _ = make(pruneSupport + "/updater/transaction"); _ = make(pruneRuntime + "/node-8.0.0-x64")
    let outside = make(root.appendingPathComponent("outside").path)
    try! fileManager.createSymbolicLink(atPath: pruneRuntime + "/node-7.0.0-x64", withDestinationPath: outside)
    guard case .success(pruneExpected) = ManagedNode.ensure(resources: resources, home: pruneHome, environment: environment) else { preconditionFailure("fast path with transaction") }
    precondition(fileManager.fileExists(atPath: pruneRuntime + "/node-8.0.0-x64"), "kept while a transaction exists, even on the fast path")
    try! fileManager.removeItem(atPath: pruneSupport + "/updater/transaction")
    guard case .success(pruneExpected) = ManagedNode.ensure(resources: resources, home: pruneHome, environment: environment) else { preconditionFailure("fast path after transaction") }
    precondition(!fileManager.fileExists(atPath: pruneRuntime + "/node-8.0.0-x64"), "pruned by a later fast-path ensure")
    precondition(fileManager.isExecutableFile(atPath: pruneExpected), "the current runtime is never pruned")
    precondition((try? fileManager.destinationOfSymbolicLink(atPath: pruneRuntime + "/node-7.0.0-x64")) == outside && fileManager.fileExists(atPath: outside), "symlinks are never followed or removed")

    // Hardening: `runtime` must be a real directory (never a symlink); looser permissions are tightened.
    let linked = make(root.appendingPathComponent("linked").path)
    let linkedSupport = make(ManagedNodeLogic.supportDirectory(home: linked))
    try! fileManager.createSymbolicLink(atPath: linkedSupport + "/runtime", withDestinationPath: outside)
    precondition(ManagedNode.ensure(resources: resources, home: linked, environment: environment) == .failure(.ioError("runtime")))
    precondition(((try? fileManager.contentsOfDirectory(atPath: outside)) ?? []).isEmpty, "nothing is written through a symlinked runtime")
    let loose = make(root.appendingPathComponent("loose").path)
    let looseRuntime = make(ManagedNodeLogic.supportDirectory(home: loose) + "/runtime")
    precondition(chmod(looseRuntime, 0o755) == 0)
    guard case .success = ManagedNode.ensure(resources: resources, home: loose, environment: environment) else { preconditionFailure("loose runtime install") }
    var looseInfo = stat()
    precondition(stat(looseRuntime, &looseInfo) == 0 && looseInfo.st_mode & 0o777 == 0o700, "runtime directory is tightened to 0700")

    // Damaged bundles and failing checks publish nothing and leave no staging behind.
    func bundle(_ label: String, entries: [String], binarySHA256: String? = nil, populate: (String) -> Void) -> String {
        let dir = make(root.appendingPathComponent("bundle-\(label)/content").path)
        populate(dir)
        let bundleResources = make(root.appendingPathComponent("bundle-\(label)/Resources/node").path)
        let tarball = bundleResources + "/node-x64.tar.xz"
        let packer = Process()
        packer.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        packer.arguments = ["-cJf", tarball, "-C", dir] + entries
        packer.environment = ["COPYFILE_DISABLE": "1"]
        try! packer.run(); packer.waitUntilExit()
        precondition(packer.terminationStatus == 0, "fixture archive \(label)")
        let data = try! Data(contentsOf: URL(fileURLWithPath: tarball))
        let object: [String: Any] = [
            "schema": 1, "version": "9.9.9", "teamIdentifier": "ABCDE12345",
            "arches": ["x64": ["archive": "node-x64.tar.xz", "archiveSize": data.count, "archiveSHA256": sha256Hex(data),
                               "binarySize": nodeBytes.count, "binarySHA256": binarySHA256 ?? sha256Hex(nodeBytes)]],
        ]
        try! JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: bundleResources + "/manifest.json"))
        return bundleResources
    }
    func writeNode(_ dir: String) { try! nodeBytes.write(to: URL(fileURLWithPath: dir + "/node")); try! Data("license".utf8).write(to: URL(fileURLWithPath: dir + "/LICENSE")) }
    func assertRefused(_ label: String, _ resourcesPath: String, _ expectedError: ManagedNodeError, using env: ManagedNode.Environment) {
        let isolatedHome = make(root.appendingPathComponent("home-\(label)").path)
        precondition(ManagedNode.ensure(resources: resourcesPath, home: isolatedHome, environment: env) == .failure(expectedError), label)
        let runtimeEntries = ((try? fileManager.contentsOfDirectory(atPath: ManagedNodeLogic.runtimeDirectory(support: ManagedNodeLogic.supportDirectory(home: isolatedHome)))) ?? [])
        precondition(runtimeEntries.filter { $0.hasPrefix("node-") || $0.hasPrefix(".extract-") }.isEmpty, "\(label) leaves nothing behind: \(runtimeEntries)")
    }
    assertRefused("extra-entry", bundle("extra", entries: ["node", "LICENSE", "EXTRA"]) { writeNode($0); try! Data("x".utf8).write(to: URL(fileURLWithPath: $0 + "/EXTRA")) }, .contentsInvalid, using: environment)
    assertRefused("symlink-node", bundle("symlink", entries: ["node", "LICENSE"]) {
        try! Data("license".utf8).write(to: URL(fileURLWithPath: $0 + "/LICENSE"))
        try! nodeBytes.write(to: URL(fileURLWithPath: $0 + "/real"))
        try! FileManager.default.createSymbolicLink(atPath: $0 + "/node", withDestinationPath: "real")
    }, .contentsInvalid, using: environment)
    assertRefused("binary-mismatch", bundle("mismatch", entries: ["node", "LICENSE"], binarySHA256: String(repeating: "c", count: 64), populate: writeNode), .binaryMismatch, using: environment)
    var failingSignature = environment
    failingSignature.signingTeam = { _ in .failure(.signatureInvalid) }
    assertRefused("signature-failure", bundle("signature", entries: ["node", "LICENSE"], populate: writeNode), .signatureInvalid, using: failingSignature)

    // arm64 hardware falls back to an x64-only bundle (runs under Rosetta).
    var armHardware = environment
    armHardware.arm64Capable = { true }
    guard case .success(let rosettaNode) = ManagedNode.ensure(resources: bundle("rosetta", entries: ["node", "LICENSE"], populate: writeNode), home: make(root.appendingPathComponent("home-rosetta").path), environment: armHardware) else { preconditionFailure("x64-only bundle on arm64 hardware") }
    precondition(rosettaNode.hasSuffix("/node-9.9.9-x64/node"))

    // A missing or invalid bundle description is a typed failure.
    precondition(ManagedNode.ensure(resources: root.path + "/nowhere", home: fresh, environment: environment) == .failure(.manifestMissing))
}
