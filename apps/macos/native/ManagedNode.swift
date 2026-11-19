import Foundation
import CryptoKit
import Darwin

// The bundled Node runtime. The app ships compressed, hash-pinned Node archives only; a quarantined copy of the
// official (non-notarized) binary is killed by Gatekeeper, so Node is never executed inside the bundle. It is extracted
// on demand into a stable per-user directory (files created by this process carry no quarantine) and every Node child
// process runs from there.

// MARK: - Errors

enum ManagedNodeError: Error, Equatable {
    case manifestMissing
    case manifestInvalid
    case archUnavailable(String)
    case archiveMissing
    case archiveMismatch
    case extractionFailed
    case contentsInvalid
    case binaryMismatch
    case signatureInvalid
    case quarantined
    case ioError(String)

    /// Controlled UI text. It names the bundled runtime and never a user path or process output.
    var userMessage: String {
        let remedy = "Download OMP Usage again and reinstall it."
        switch self {
        case .manifestMissing, .manifestInvalid:
            return "The bundled Node.js runtime description is missing or invalid. \(remedy)"
        case .archUnavailable:
            return "The bundled Node.js runtime does not include this Mac's processor type. \(remedy)"
        case .archiveMissing, .archiveMismatch, .contentsInvalid, .binaryMismatch:
            return "The bundled Node.js runtime is damaged. \(remedy)"
        case .extractionFailed:
            return "The bundled Node.js runtime could not be unpacked. Check free disk space and permissions on your home folder, then try again."
        case .signatureInvalid:
            return "The bundled Node.js runtime failed its signature check. \(remedy)"
        case .quarantined:
            return "The unpacked Node.js runtime was blocked by macOS quarantine. Restart OMP Usage and try again."
        case .ioError:
            return "The bundled Node.js runtime could not be prepared. Check free disk space and permissions on your home folder, then try again."
        }
    }
}

// MARK: - Manifest

struct ManagedNodeArchive: Equatable {
    let archive: String
    let archiveSize: Int
    let archiveSHA256: String
    let binarySize: Int
    let binarySHA256: String
}

struct ManagedNodeManifest: Equatable {
    static let knownArches = ["arm64", "x64"]
    let version: String
    let teamIdentifier: String
    let arches: [String: ManagedNodeArchive]

    /// Strict: exactly the documented keys, no extras, canonical names and digests.
    static func parse(_ data: Data) throws -> ManagedNodeManifest {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["schema", "version", "teamIdentifier", "arches"],
              integer(root["schema"]) == 1,
              let version = root["version"] as? String, matches(version, #"\A\d+\.\d+\.\d+\z"#),
              let team = root["teamIdentifier"] as? String, matches(team, #"\A[A-Z0-9]{10}\z"#),
              let rawArches = root["arches"] as? [String: Any], !rawArches.isEmpty
        else { throw ManagedNodeError.manifestInvalid }
        var arches: [String: ManagedNodeArchive] = [:]
        for (name, value) in rawArches {
            guard knownArches.contains(name), let entry = value as? [String: Any],
                  Set(entry.keys) == ["archive", "archiveSize", "archiveSHA256", "binarySize", "binarySHA256"],
                  let archive = entry["archive"] as? String, archive == "node-\(name).tar.xz",
                  let archiveSize = integer(entry["archiveSize"]), archiveSize > 0,
                  let archiveSHA = entry["archiveSHA256"] as? String, matches(archiveSHA, #"\A[0-9a-f]{64}\z"#),
                  let binarySize = integer(entry["binarySize"]), binarySize > 0,
                  let binarySHA = entry["binarySHA256"] as? String, matches(binarySHA, #"\A[0-9a-f]{64}\z"#)
            else { throw ManagedNodeError.manifestInvalid }
            arches[name] = ManagedNodeArchive(archive: archive, archiveSize: archiveSize, archiveSHA256: archiveSHA, binarySize: binarySize, binarySHA256: binarySHA)
        }
        return ManagedNodeManifest(version: version, teamIdentifier: team, arches: arches)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// A JSON integer only: booleans and fractional numbers are rejected.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number as CFNumber) else { return nil }
        return number.intValue
    }
}

// MARK: - Marker

/// `complete.json`, written last inside the extracted directory: its presence and content prove a finished,
/// verified extraction of exactly this manifest entry.
struct ManagedNodeMarker: Codable, Equatable {
    let schema: Int
    let version: String
    let arch: String
    let binarySize: Int
    let binarySHA256: String

    init(manifest: ManagedNodeManifest, arch: String, entry: ManagedNodeArchive) {
        schema = 1; version = manifest.version; self.arch = arch
        binarySize = entry.binarySize; binarySHA256 = entry.binarySHA256
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct ManagedNodeFileInfo: Equatable {
    let isRegular: Bool
    let isExecutable: Bool
    let size: Int

    static func inspect(_ path: String) -> ManagedNodeFileInfo? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return ManagedNodeFileInfo(isRegular: (info.st_mode & S_IFMT) == S_IFREG, isExecutable: access(path, X_OK) == 0, size: Int(info.st_size))
    }
}

// MARK: - Pure decisions

enum ManagedNodeLogic {
    static let directoryPrefix = "node-"
    static let extractPrefix = ".extract-"

    static func supportDirectory(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/omp-usage-panel")
    }
    static func runtimeDirectory(support: String) -> String { (support as NSString).appendingPathComponent("runtime") }
    static func directoryName(version: String, arch: String) -> String { "\(directoryPrefix)\(version)-\(arch)" }
    static func transactionPath(support: String) -> String { (support as NSString).appendingPathComponent("updater/transaction") }

    /// Native arm64 hardware runs the arm64 build even when this process is an x86_64 slice under Rosetta.
    static func chooseArch(arm64Capable: Bool, manifest: ManagedNodeManifest) throws -> String {
        // arm64 hardware prefers the arm64 build but can run an x64-only manifest under Rosetta.
        let candidates = arm64Capable ? ["arm64", "x64"] : ["x64"]
        guard let arch = candidates.first(where: { manifest.arches[$0] != nil }) else { throw ManagedNodeError.archUnavailable(candidates[0]) }
        return arch
    }

    /// Fast path: no hashing. The marker must equal the manifest entry and the binary must look like the verified one.
    static func isComplete(markerData: Data?, expected: ManagedNodeMarker, node: ManagedNodeFileInfo?) -> Bool {
        guard let markerData, let marker = try? JSONDecoder().decode(ManagedNodeMarker.self, from: markerData), marker == expected,
              let node, node.isRegular, node.isExecutable, node.size == expected.binarySize else { return false }
        return true
    }

    /// Superseded runtimes are pruned only when no update transaction is in flight (a rollback may still need the
    /// version that wrote it). Only `node-*` siblings other than the current one are ever candidates.
    static func prunable(entries: [String], current: String, transactionExists: Bool) -> [String] {
        guard !transactionExists else { return [] }
        return entries.filter { $0.hasPrefix(directoryPrefix) && $0 != current }.sorted()
    }

    /// Abandoned extraction directories are ours and only touched while holding the runtime lock.
    static func staleExtractions(entries: [String]) -> [String] { entries.filter { $0.hasPrefix(extractPrefix) }.sorted() }

    /// `TeamIdentifier=XXXXXXXXXX` from `codesign -dv` output.
    static func teamIdentifier(fromCodesignOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            return String(line.dropFirst("TeamIdentifier=".count))
        }
        return nil
    }
}

// MARK: - Provisioning

enum ManagedNode {
    /// Cross-thread serialization; the file lock below serializes processes (app start, Setup, the update helper).
    private static let processLock = NSLock()
    private static let toolTimeout: TimeInterval = 180

    /// Seams for the parts that need the machine: processor type and the code-signing check.
    struct Environment {
        var arm64Capable: () -> Bool = {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        }
        /// Returns the verified Team Identifier of the Mach-O at `path`.
        var signingTeam: (String) -> Result<String, ManagedNodeError> = ManagedNode.codesignTeam
    }

    /// Absolute path of the managed `node`, extracting it from `bundle` first when needed. Blocking (first run
    /// takes seconds): never call on the main thread.
    static func ensure(bundle: Bundle, home: String = NSHomeDirectory(), environment: Environment = Environment()) -> Result<String, ManagedNodeError> {
        guard let resources = bundle.resourceURL?.appendingPathComponent("node") else { return .failure(.manifestMissing) }
        return ensure(resources: resources.path, home: home, environment: environment)
    }

    static func ensure(resources: String, home: String, environment: Environment = Environment()) -> Result<String, ManagedNodeError> {
        do {
            guard let data = FileManager.default.contents(atPath: (resources as NSString).appendingPathComponent("manifest.json")) else { throw ManagedNodeError.manifestMissing }
            let manifest = try ManagedNodeManifest.parse(data)
            let arch = try ManagedNodeLogic.chooseArch(arm64Capable: environment.arm64Capable(), manifest: manifest)
            guard let entry = manifest.arches[arch] else { throw ManagedNodeError.archUnavailable(arch) }
            let support = ManagedNodeLogic.supportDirectory(home: home)
            let runtime = ManagedNodeLogic.runtimeDirectory(support: support)
            let name = ManagedNodeLogic.directoryName(version: manifest.version, arch: arch)
            let directory = (runtime as NSString).appendingPathComponent(name)
            let node = (directory as NSString).appendingPathComponent("node")
            let marker = ManagedNodeMarker(manifest: manifest, arch: arch, entry: entry)
            if isComplete(directory: directory, expected: marker) {
                pruneSuperseded(runtime: runtime, current: name, support: support)
                return .success(node)
            }

            try prepareRuntimeDirectory(runtime)
            try withRuntimeLock(runtime) {
                // Another process may have finished while this one waited.
                if isComplete(directory: directory, expected: marker) { prune(runtime: runtime, current: name, support: support); return }
                try install(resources: resources, manifest: manifest, arch: arch, entry: entry, marker: marker, runtime: runtime, name: name, environment: environment)
                prune(runtime: runtime, current: name, support: support)
            }
            return .success(node)
        } catch let error as ManagedNodeError {
            return .failure(error)
        } catch {
            return .failure(.ioError("unexpected"))
        }
    }

    private static func isComplete(directory: String, expected: ManagedNodeMarker) -> Bool {
        let node = (directory as NSString).appendingPathComponent("node")
        return ManagedNodeLogic.isComplete(markerData: FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent("complete.json")),
                                           expected: expected, node: ManagedNodeFileInfo.inspect(node))
    }

    /// `runtime` must be a real directory owned by this user with no group/other access, never a symlink.
    private static func prepareRuntimeDirectory(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw ManagedNodeError.ioError("mkdir") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw ManagedNodeError.ioError("runtime") }
        if info.st_mode & 0o077 != 0 { guard chmod(path, 0o700) == 0 else { throw ManagedNodeError.ioError("runtime") } }
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Serializes threads (process lock) and processes (flock on a regular, non-symlink `.lock` file).
    private static func withRuntimeLock<T>(_ runtime: String, _ body: () throws -> T) throws -> T {
        processLock.lock(); defer { processLock.unlock() }
        let descriptor = open((runtime as NSString).appendingPathComponent(".lock"), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ManagedNodeError.ioError("lock") }
        defer { close(descriptor) }   // closing releases the flock
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ManagedNodeError.ioError("lock") }
        while flock(descriptor, LOCK_EX) != 0 { guard errno == EINTR else { throw ManagedNodeError.ioError("lock") } }
        return try body()
    }

    // Caller holds the runtime lock.
    private static func install(resources: String, manifest: ManagedNodeManifest, arch: String, entry: ManagedNodeArchive, marker: ManagedNodeMarker,
                                runtime: String, name: String, environment: Environment) throws {
        let fileManager = FileManager.default
        let archive = (resources as NSString).appendingPathComponent(entry.archive)
        guard let archiveInfo = ManagedNodeFileInfo.inspect(archive), archiveInfo.isRegular else { throw ManagedNodeError.archiveMissing }
        guard archiveInfo.size == entry.archiveSize, try sha256(of: archive) == entry.archiveSHA256 else { throw ManagedNodeError.archiveMismatch }

        for stale in ManagedNodeLogic.staleExtractions(entries: (try? fileManager.contentsOfDirectory(atPath: runtime)) ?? []) {
            try? fileManager.removeItem(atPath: (runtime as NSString).appendingPathComponent(stale))
        }
        let staging = (runtime as NSString).appendingPathComponent(ManagedNodeLogic.extractPrefix + UUID().uuidString)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(atPath: staging) } }
        do { try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw ManagedNodeError.ioError("mkdir") }

        guard extractArchive(archive, into: staging) else { throw ManagedNodeError.extractionFailed }
        let entries = ((try? fileManager.contentsOfDirectory(atPath: staging)) ?? []).sorted()
        guard entries == ["LICENSE", "node"] else { throw ManagedNodeError.contentsInvalid }
        let node = (staging as NSString).appendingPathComponent("node")
        let license = (staging as NSString).appendingPathComponent("LICENSE")
        var linkInfo = stat()
        for path in [node, license] {
            guard lstat(path, &linkInfo) == 0, (linkInfo.st_mode & S_IFMT) == S_IFREG else { throw ManagedNodeError.contentsInvalid }
        }
        guard let nodeInfo = ManagedNodeFileInfo.inspect(node), nodeInfo.size == entry.binarySize, try sha256(of: node) == entry.binarySHA256 else { throw ManagedNodeError.binaryMismatch }
        guard chmod(node, 0o755) == 0, chmod(license, 0o644) == 0 else { throw ManagedNodeError.ioError("chmod") }
        switch environment.signingTeam(node) {
        case .success(let team): guard team == manifest.teamIdentifier else { throw ManagedNodeError.signatureInvalid }
        case .failure(let error): throw error
        }
        for extracted in [node, license] where getxattr(extracted, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 { throw ManagedNodeError.quarantined }
        do { try marker.encoded().write(to: URL(fileURLWithPath: (staging as NSString).appendingPathComponent("complete.json"))) }
        catch { throw ManagedNodeError.ioError("marker") }

        // Atomic publish. A broken previous directory is moved aside first (rename cannot replace a non-empty
        // directory); it is removed only after the new one is in place.
        let final = (runtime as NSString).appendingPathComponent(name)
        var aside: String?
        if fileManager.fileExists(atPath: final) {
            let moved = (runtime as NSString).appendingPathComponent(ManagedNodeLogic.extractPrefix + "old-" + UUID().uuidString)
            guard rename(final, moved) == 0 else { throw ManagedNodeError.ioError("replace") }
            aside = moved
        }
        guard rename(staging, final) == 0 else {
            if let aside { _ = rename(aside, final) }
            throw ManagedNodeError.ioError("publish")
        }
        committed = true
        if let aside { try? fileManager.removeItem(atPath: aside) }
    }

    /// Removes superseded `node-*` directories (real directories only; a symlink or file of that name is left alone).
    /// Caller holds the runtime lock.
    private static func prune(runtime: String, current: String, support: String) {
        let exists = FileManager.default.fileExists(atPath: ManagedNodeLogic.transactionPath(support: support))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: runtime)) ?? []
        for name in ManagedNodeLogic.prunable(entries: entries, current: current, transactionExists: exists) {
            let path = (runtime as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Fast-path pruning: a cheap listing decides whether anything is prunable; only then is the lock taken. This is
    /// what removes superseded runtimes after an update, because the first `ensure` after the update still sees the
    /// transaction. Best effort: failures never affect the returned node.
    private static func pruneSuperseded(runtime: String, current: String, support: String) {
        let exists = FileManager.default.fileExists(atPath: ManagedNodeLogic.transactionPath(support: support))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: runtime)) ?? []
        guard !ManagedNodeLogic.prunable(entries: entries, current: current, transactionExists: exists).isEmpty else { return }
        try? prepareRuntimeDirectory(runtime)
        try? withRuntimeLock(runtime) { prune(runtime: runtime, current: current, support: support) }
    }

    // MARK: Machine-dependent helpers

    private static func sha256(of path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ManagedNodeError.ioError("read") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { throw ManagedNodeError.ioError("read") }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func codesignTeam(path: String) -> Result<String, ManagedNodeError> {
        guard let verify = runTool("/usr/bin/codesign", ["--verify", "--strict", path]), verify.status == 0 else { return .failure(.signatureInvalid) }
        guard let details = runTool("/usr/bin/codesign", ["-dv", "--verbose=2", path]), details.status == 0,
              let team = ManagedNodeLogic.teamIdentifier(fromCodesignOutput: details.stderr) else { return .failure(.signatureInvalid) }
        return .success(team)
    }

    /// `tar -xJf - -C staging` fed through a Pipe. tar copies the archive file's `com.apple.quarantine` xattr onto
    /// every extracted file when it opens a quarantined archive by path or reads it through an fd of that file, and a
    /// quarantined unnotarized node is killed on exec. Bytes arriving through a pipe carry no such attribute.
    private static func extractArchive(_ archive: String, into staging: String) -> Bool {
        guard let source = FileHandle(forReadingAtPath: archive) else { return false }
        defer { try? source.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xJf", "-", "-C", staging]
        task.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let input = Pipe()
        task.standardInput = input
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch { return false }
        try? input.fileHandleForReading.close()
        // A write after tar exits must fail with EPIPE, never raise SIGPIPE in the app.
        let writeDescriptor = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeDescriptor, F_SETNOSIGPIPE, 1)
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { try? input.fileHandleForWriting.close(); writer.leave() }
            while let chunk = try? source.read(upToCount: 1 << 20), !chunk.isEmpty {
                var offset = 0
                let ok = chunk.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
                    while offset < buffer.count {
                        let written = write(writeDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
                        if written < 0 { if errno == EINTR { continue }; return false }
                        offset += written
                    }
                    return true
                }
                if !ok { return }
            }
        }
        if exited.wait(timeout: .now() + toolTimeout) == .timedOut {
            task.terminate()
            _ = exited.wait(timeout: .now() + 5)
            if task.isRunning { kill(task.processIdentifier, SIGKILL); exited.wait() }
            _ = writer.wait(timeout: .now() + 5)
            return false
        }
        writer.wait()
        return task.terminationStatus == 0
    }

    /// Runs a system tool with discarded stdout, captured stderr and a hard timeout. nil: could not run or timed out.
    private static func runTool(_ executable: String, _ arguments: [String]) -> (status: Int32, stderr: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        task.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch { return nil }
        let readers = DispatchGroup()
        let collected = NSLock()
        var output = Data()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            collected.lock(); output = data; collected.unlock()
            readers.leave()
        }
        if exited.wait(timeout: .now() + toolTimeout) == .timedOut {
            task.terminate()
            _ = exited.wait(timeout: .now() + 5)
            if task.isRunning { kill(task.processIdentifier, SIGKILL); exited.wait() }
            _ = readers.wait(timeout: .now() + 5)
            return nil
        }
        readers.wait()
        collected.lock(); let data = output; collected.unlock()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
