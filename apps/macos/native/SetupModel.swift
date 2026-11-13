import Foundation

// Pure, Foundation-only model of the one-time first-run setup: launch routing, environment discovery, the
// editable draft, the strict helper JSON protocol and the child-process environment. It never touches the
// filesystem except through injected closures and the explicit read helpers below, and it never writes.

// MARK: - Launch routing

enum SetupLaunchRoute: Equatable {
    /// `--config path`: the existing fast managed path. Unchanged by setup.
    case normal(configPath: String)
    /// No arguments from the canonical managed app: hand off to the registered job through the bundled helper.
    case managedHandoff
    /// No arguments from any other location (DMG, Downloads, an uncanonical copy): one-time setup.
    case setup
    /// `--install [--omp /absolute/path] [--profile name]`: the headless install transaction, no UI at all.
    case install(omp: String?, profile: String?)
    case usage
}

enum SetupLaunch {
    static let canonicalRelativePath = "Applications/OMP Usage.app"
    static let helperRelativePath = "runtime/apps/macos/setup-install.mjs"

    static func canonicalAppPath(home: String) -> String { (home as NSString).appendingPathComponent(canonicalRelativePath) }

    /// `resolve` canonicalizes a path (symlinks, `..`); an unresolvable path must come back standardized, not nil.
    static func route(arguments: [String], bundlePath: String, home: String, resolve: (String) -> String) -> SetupLaunchRoute {
        if arguments.count == 3 && arguments[1] == "--config" { return .normal(configPath: arguments[2]) }
        if arguments.count >= 2 && arguments[1] == "--install" { return installRoute(Array(arguments.dropFirst(2))) }
        guard arguments.count == 1 else { return .usage }
        let canonical = resolve(canonicalAppPath(home: home))
        return resolve(bundlePath) == canonical ? .managedHandoff : .setup
    }

    static let usageText = "Usage: OMPUsagePanel [--config path] | --install [--omp /absolute/path] [--profile name]"

    /// Options after `--install`: `--omp` (absolute) and `--profile` (not blank, not another option), each at most
    /// once in any order, every value required. Anything else is a usage error.
    private static func installRoute(_ options: [String]) -> SetupLaunchRoute {
        var omp: String?, profile: String?
        var index = 0
        while index < options.count {
            guard index + 1 < options.count else { return .usage }
            let value = options[index + 1]
            switch options[index] {
            case "--omp":
                guard omp == nil, value.hasPrefix("/") else { return .usage }
                omp = value
            case "--profile":
                guard profile == nil, !PanelConfig.isBlank(value), !value.hasPrefix("--") else { return .usage }
                profile = value
            default: return .usage
            }
            index += 2
        }
        return .install(omp: omp, profile: profile)
    }

    static func resolvingSymlinks(_ path: String) -> String {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        return (path as NSString).standardizingPath
    }

    static func defaultConfigPath(home: String) -> String {
        (ManagedNodeLogic.supportDirectory(home: home) as NSString).appendingPathComponent("config.json")
    }
}

// MARK: - File inspection

enum SetupFileKind: Equatable {
    case missing
    case directory
    case file(executable: Bool)

    /// stat(2) kind (symlinks followed) plus the access(2) execute bit. Never reads file content.
    static func inspect(_ path: String) -> SetupFileKind {
        var info = stat()
        guard stat(path, &info) == 0 else { return .missing }
        if (info.st_mode & S_IFMT) == S_IFDIR { return .directory }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .file(executable: false) }
        return .file(executable: access(path, X_OK) == 0)
    }
}

enum SetupPathIssue: Equatable {
    case empty, notAbsolute, missing, directory, notExecutable

    static func check(_ path: String, kind: (String) -> SetupFileKind) -> SetupPathIssue? {
        if PanelConfig.isBlank(path) { return .empty }
        guard path.hasPrefix("/") else { return .notAbsolute }
        switch kind(path) {
        case .missing: return .missing
        case .directory: return .directory
        case .file(let executable): return executable ? nil : .notExecutable
        }
    }

    func message(subject: String) -> String {
        switch self {
        case .empty: return "Enter the absolute path to \(subject)."
        case .notAbsolute: return "Use an absolute path starting with /."
        case .missing: return "No file exists at this path."
        case .directory: return "This path is a folder. Choose the \(subject) executable file."
        case .notExecutable: return "This file is not executable."
        }
    }
}

// MARK: - Discovery

struct SetupDiscoveryEnvironment {
    var home: String
    var path: String?
    var kind: (String) -> SetupFileKind = SetupFileKind.inspect
}

/// Deterministic candidate ordering. Order IS the preference: earlier candidates win ties. Only absolute paths that
/// are executable regular files (never directories) are returned; duplicates keep their first position.
enum SetupDiscovery {
    static func pathDirectories(_ path: String?) -> [String] {
        (path ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init).filter { $0.hasPrefix("/") }
    }

    /// PATH, `~/.local/bin`, `~/.bun/bin`, then Homebrew.
    static func ompCandidates(_ env: SetupDiscoveryEnvironment) -> [String] {
        var ordered = pathDirectories(env.path).map { ($0 as NSString).appendingPathComponent("omp") }
        ordered += [(env.home as NSString).appendingPathComponent(".local/bin/omp"), (env.home as NSString).appendingPathComponent(".bun/bin/omp"),
                    "/opt/homebrew/bin/omp", "/usr/local/bin/omp"]
        return usable(ordered, env)
    }

    private static func usable(_ candidates: [String], _ env: SetupDiscoveryEnvironment) -> [String] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            guard seen.insert(candidate).inserted else { return false }
            if case .file(true) = env.kind(candidate) { return true }
            return false
        }
    }
}

// MARK: - Existing configuration

enum SetupExistingConfig: Equatable {
    /// No file at the default path: a fresh install that creates the default configuration.
    case none
    /// A valid configuration. It is authoritative and is never rewritten by setup.
    case valid(PanelConfig)
    /// Present but unreadable or invalid. Setup refuses; it never resets or replaces the file.
    case refused(String)

    static func read(path: String) -> SetupExistingConfig {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return .none }
            return .refused("The existing configuration cannot be inspected: \(String(cString: strerror(errno))).")
        }
        do { return .valid(try PanelConfigStore.load(path: path)) }
        catch { return .refused((error as? PanelConfigError)?.errorDescription ?? "The existing configuration cannot be read.") }
    }
}

// MARK: - Request / response protocol

/// One strict request object. Optional fields are omitted from the JSON when nil.
struct SetupRequest: Encodable, Equatable {
    let sourceAppPath: String
    let hostPid: Int
    let ompPath: String?
    let profile: String?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum SetupCommand: String { case install, launch }

enum SetupAction: String, Equatable { case relaunch, activate, `continue` }

struct SetupSuccess: Equatable {
    let command: SetupCommand
    let action: SetupAction
    let appPath: String
    let configPath: String
    let pid: Int?
}

struct SetupFailure: Error, Equatable {
    let code: String
    /// Controlled text for failures that originate in this app (never helper or process output).
    var detail: String? = nil
    /// Controlled, fixed UI text chosen by `code`. Helper-supplied messages are never displayed.
    var userMessage: String {
        switch code {
        case "running":
            return "Another OMP Usage process is still running. Save your work in it, quit it, then try Install & Open again."
        case "update-in-progress", "transaction":
            return "An OMP Usage update is in progress or waiting to be confirmed. Open the installed OMP Usage app from Applications so it can finish and confirm the update, then try again."
        case "ownership-mismatch":
            return "An existing update belongs to a different installation location. Nothing was changed. Finish or recover that installation before setting up this copy."
        case "busy":
            return "Another OMP Usage install or update is busy. Wait a moment, then try again."
        case "node-unavailable":
            return detail ?? "The bundled Node.js runtime could not be prepared or started. Download OMP Usage again and reinstall it, then try again."
        case "omp-unavailable":
            return "The omp executable could not be used. Choose a valid omp executable, then try again."
        case "invalid-profile":
            return "The profile name is not valid. Enter a different profile name, then try again."
        case "config-invalid", "config-changed":
            return "The existing configuration is invalid or changed during setup. It was not reset or replaced. Fix or move that file, then open this app again."
        case "not-managed":
            return "This copy is not registered as the managed OMP Usage yet. Use Install & Open to set it up."
        case "foreign-app", "foreign-agent", "foreign-job", "foreign-state":
            return "A different app, login item or job already occupies the OMP Usage location, so setup will not overwrite it. Review it yourself; setup never replaces files it does not own."
        case "source-mismatch", "invalid-source":
            return "This copy of OMP Usage is not intact or is not being run from its own app. Download it again and open the app from the disk image."
        case "invalid-request", "invalid-response", "missing-helper":
            return "Setup did not return a confirmed result, so this window cannot tell whether anything was installed. Check ~/Applications/OMP Usage.app and the login item before trying again. Existing files are left as they are."
        case "rollback-incomplete", "state-unsafe", "manifest-invalid":
            return "Setup stopped because the existing installation record or its permissions are not in a safe state. Keep the installed app and any backup files as they are, review the installation record and permissions, and seek repair. Do not force an overwrite or clean up by hand."
        case "copy-failed", "install-failed", "io-error":
            return "Setup could not copy or register the app. Check free disk space and permissions on your home folder, then try again."
        case "unsupported":
            return "This macOS setup is not supported on this system."
        case "timeout":
            return "Setup took too long and was stopped. Check that the paths are correct and try again."
        default:
            return "Setup could not be completed (\(code)). Your entries are kept; fix the problem and try again."
        }
    }
}

enum SetupResponse {
    private static let codePattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,39}\\z")

    /// A code safe to print; anything else becomes `failed`.
    static func sanitizedCode(_ raw: String) -> String {
        codePattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil ? raw : "failed"
    }

    private struct Envelope: Decodable {
        struct Problem: Decodable { let code: String }
        let ok: Bool
        let command: String?
        let action: String?
        let appPath: String?
        let configPath: String?
        let pid: Int?
        let error: Problem?
    }

    static func parse(stdout: Data, exitStatus: Int32, command: SetupCommand) -> Result<SetupSuccess, SetupFailure> {
        let invalid = SetupFailure(code: "invalid-response")
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: stdout), envelope.command == command.rawValue else { return .failure(invalid) }
        if envelope.ok {
            guard exitStatus == 0, let raw = envelope.action, let action = SetupAction(rawValue: raw),
                  let appPath = envelope.appPath, appPath.hasPrefix("/"), let configPath = envelope.configPath, configPath.hasPrefix("/")
            else { return .failure(invalid) }
            if let pid = envelope.pid, pid <= 0 { return .failure(invalid) }
            if action == .activate && envelope.pid == nil { return .failure(invalid) }
            return .success(SetupSuccess(command: command, action: action, appPath: appPath, configPath: configPath, pid: envelope.pid))
        }
        guard let problem = envelope.error else { return .failure(invalid) }
        return .failure(SetupFailure(code: sanitizedCode(problem.code)))
    }
}

// MARK: - Draft

/// Editable first-run form. With a valid existing configuration the draft is read-only and every value shown comes
/// from that file; nothing typed can reach the request. With none, defaults are suggestions the user confirms by
/// pressing Install & Open; with a refused configuration setup is blocked.
struct SetupDraft: Equatable {
    static let defaultProfile = "default"

    let existing: SetupExistingConfig
    private(set) var ompPath: String
    private(set) var profile: String
    private let initialOmpPath: String
    private(set) var ompKind: (path: String, kind: SetupFileKind)?

    static func == (lhs: SetupDraft, rhs: SetupDraft) -> Bool {
        lhs.existing == rhs.existing && lhs.ompPath == rhs.ompPath && lhs.profile == rhs.profile
            && lhs.ompKind?.path == rhs.ompKind?.path && lhs.ompKind?.kind == rhs.ompKind?.kind
    }

    /// `suggestedOmp` is only used when there is no existing configuration.
    init(existing: SetupExistingConfig, suggestedOmp: String = "") {
        self.existing = existing
        if case .valid(let config) = existing {
            ompPath = config.ompPath; profile = config.profile
        } else {
            ompPath = suggestedOmp; profile = Self.defaultProfile
        }
        initialOmpPath = ompPath
    }

    var isReadOnly: Bool { if case .valid = existing { return true }; return false }
    var isRefused: Bool { if case .refused = existing { return true }; return false }
    var refusalMessage: String? { if case .refused(let message) = existing { return message }; return nil }

    /// Edits are ignored while read-only, so a valid configuration can never be changed through this draft.
    mutating func setOmpPath(_ value: String) { guard !isReadOnly, value != ompPath else { return }; ompPath = value; ompKind = nil }
    mutating func setProfile(_ value: String) { guard !isReadOnly else { return }; profile = value }
    mutating func record(ompKind kind: SetupFileKind, for path: String) { if path == ompPath { ompKind = (path, kind) } }

    /// True once the user changed anything from what was first shown. Always false while read-only.
    var isDirty: Bool {
        !isReadOnly && (ompPath != initialOmpPath || profile != Self.defaultProfile)
    }

    // Field problems, evaluated against injected file kinds so tests need no filesystem.
    func ompIssue(kind: (String) -> SetupFileKind = SetupFileKind.inspect) -> SetupPathIssue? { SetupPathIssue.check(ompPath, kind: kind) }
    var profileIsBlank: Bool { PanelConfig.isBlank(profile) }

    enum Blocker: Equatable {
        case refusedConfig
        case omp(SetupPathIssue), profile
    }

    /// The first reason Install & Open is unavailable, in display order; nil when ready.
    func blocker(kind: (String) -> SetupFileKind = SetupFileKind.inspect) -> Blocker? {
        if isRefused { return .refusedConfig }
        // A valid existing configuration is authoritative: its omp path and profile are not re-validated here.
        if isReadOnly { return nil }
        if let issue = ompIssue(kind: kind) { return .omp(issue) }
        if profileIsBlank { return .profile }
        return nil
    }

    func canInstall(kind: (String) -> SetupFileKind = SetupFileKind.inspect) -> Bool { blocker(kind: kind) == nil }

    /// Read-only: only the source path and host PID (the existing config is authoritative). Otherwise the two
    /// confirmed values. nil while blocked.
    func request(sourceAppPath: String, hostPid: Int, kind: (String) -> SetupFileKind = SetupFileKind.inspect) -> SetupRequest? {
        guard canInstall(kind: kind) else { return nil }
        if isReadOnly { return SetupRequest(sourceAppPath: sourceAppPath, hostPid: hostPid, ompPath: nil, profile: nil) }
        return SetupRequest(sourceAppPath: sourceAppPath, hostPid: hostPid, ompPath: ompPath, profile: profile)
    }

    func blockerMessage(_ blocker: Blocker) -> String {
        switch blocker {
        case .refusedConfig: return refusalMessage ?? "The existing configuration cannot be used."
        case .omp(let issue): return "omp: " + issue.message(subject: "omp")
        case .profile: return "Enter a profile name."
        }
    }
}

// MARK: - Headless install (`--install`)

/// What the headless installer prints and returns. `stdout`/`stderr` are single controlled lines (no trailing newline).
struct SetupInstallReport: Equatable {
    let exitCode: Int32
    let stdout: String?
    let stderr: String?

    static func failed(_ message: String, exitCode: Int32) -> SetupInstallReport {
        let line = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        return SetupInstallReport(exitCode: exitCode, stdout: nil, stderr: "OMP Usage install failed: " + line)
    }
}

enum SetupInstallPlan: Equatable {
    /// Run the helper's install. `ompPath` only seeds the child environment; `notes` are stderr lines printed first.
    case run(request: SetupRequest, ompPath: String, notes: [String])
    /// Nothing is run: print the report and exit.
    case stop(SetupInstallReport)
}

enum SetupInstallCLI {
    static let ompNotFound = "omp not found; pass --omp /absolute/path"
    static let ignoredNote = "OMP Usage install note: OMP Usage is already set up; --omp and --profile were ignored and the existing configuration was kept."

    /// The same request rules as the Setup window (`SetupDraft` decides): a valid existing configuration is read-only and
    /// authoritative, an invalid one is refused, otherwise omp is `--omp`, else the first usable discovered one.
    static func plan(omp: String?, profile: String?, existing: SetupExistingConfig, discovery: SetupDiscoveryEnvironment,
                     sourceAppPath: String, hostPid: Int) -> SetupInstallPlan {
        let suggested: String
        switch existing {
        case .refused(let message):
            return .stop(.failed(message + " Setup will not replace or reset this file. Fix or move it, then run the installer again.", exitCode: 1))
        case .valid: suggested = ""
        case .none:
            suggested = omp ?? SetupDiscovery.ompCandidates(discovery).first ?? ""
            if suggested.isEmpty { return .stop(.failed(ompNotFound, exitCode: 2)) }
        }
        var draft = SetupDraft(existing: existing, suggestedOmp: suggested)
        if let profile { draft.setProfile(profile) }
        if let blocker = draft.blocker(kind: discovery.kind) { return .stop(.failed(draft.blockerMessage(blocker), exitCode: 2)) }
        guard let request = draft.request(sourceAppPath: sourceAppPath, hostPid: hostPid, kind: discovery.kind) else {
            return .stop(.failed("The install request could not be prepared.", exitCode: 1))
        }
        let notes = draft.isReadOnly && (omp != nil || profile != nil) ? [ignoredNote] : []
        return .run(request: request, ompPath: draft.ompPath, notes: notes)
    }

    /// Success is one stdout line with the installed app path. A `continue` action never happens for an install and is
    /// treated like any unconfirmed result.
    static func report(for result: Result<SetupSuccess, SetupFailure>) -> SetupInstallReport {
        switch result {
        case .success(let success) where success.action != .continue:
            return SetupInstallReport(exitCode: 0, stdout: "OMP Usage installed: " + success.appPath, stderr: nil)
        case .success: return report(for: .failure(SetupFailure(code: "invalid-response")))
        case .failure(let failure):
            return .failed(message(for: failure), exitCode: ["omp-unavailable", "invalid-profile"].contains(failure.code) ? 2 : 1)
        }
    }

    /// Controlled one-sentence text per failure code. Helper-supplied text is never shown.
    static func message(for failure: SetupFailure) -> String {
        switch failure.code {
        case "running":
            return "OMP Usage is running; quit it (menu bar panel -> Options -> Quit) and run the installer again."
        case "update-in-progress", "transaction":
            return "An OMP Usage update is in progress or waiting to be confirmed. Open the installed OMP Usage app from Applications so it can finish and confirm the update, then run the installer again."
        case "ownership-mismatch":
            return "An existing update belongs to a different installation location. Nothing was changed. Finish or recover that installation first."
        case "busy":
            return "Another OMP Usage install or update is busy. Wait a moment, then run the installer again."
        case "node-unavailable":
            return failure.detail ?? "The bundled Node.js runtime could not be prepared or started. Download OMP Usage again, then run the installer again."
        case "omp-unavailable":
            return "The omp executable could not be used. Pass a valid one with --omp /absolute/path."
        case "invalid-profile":
            return "The profile name is not valid. Pass a different one with --profile."
        case "config-invalid", "config-changed":
            return "The existing configuration is invalid or changed during setup. It was not reset or replaced. Fix or move that file, then run the installer again."
        case "not-managed":
            return "This copy is not registered as the managed OMP Usage."
        case "foreign-app", "foreign-agent", "foreign-job", "foreign-state":
            return "A different app, login item or job already occupies the OMP Usage location, so the installer will not overwrite it. Review it yourself; the installer never replaces files it does not own."
        case "source-mismatch", "invalid-source":
            return "This copy of OMP Usage is not intact. Run the one-line installer again to download it afresh."
        case "invalid-request", "invalid-response", "missing-helper":
            return "The installer did not return a confirmed result, so it cannot tell whether anything was installed. Check ~/Applications/OMP Usage.app and the login item before trying again. Existing files are left as they are."
        case "rollback-incomplete", "state-unsafe", "manifest-invalid":
            return "The installer stopped because the existing installation record or its permissions are not in a safe state. Keep the installed app and any backup files as they are and seek repair. Do not force an overwrite or clean up by hand."
        case "copy-failed", "install-failed", "io-error":
            return "The installer could not copy or register the app. Check free disk space and permissions on your home folder, then run it again."
        case "unsupported":
            return "This macOS setup is not supported on this system."
        case "timeout":
            return "The installer took too long and was stopped. Run it again."
        default:
            return "The installer could not complete (\(failure.code)). Fix the problem and run it again."
        }
    }
}

// MARK: - Install lifecycle

/// Quit handling while setup is running. A mutating install is never interrupted by a quit request; the quit is
/// remembered and honoured after the helper finishes (unless the handoff exits anyway).
struct SetupQuitGate: Equatable {
    private(set) var isMutating = false
    private(set) var quitRequested = false

    enum Reply: Equatable { case terminateNow, hold }

    mutating func beginMutation() { isMutating = true; quitRequested = false }
    /// Returns true when a deferred quit should now proceed.
    mutating func endMutation() -> Bool { isMutating = false; defer { quitRequested = false }; return quitRequested }
    mutating func quitAsked() -> Reply {
        if isMutating { quitRequested = true; return .hold }
        return .terminateNow
    }
}

// MARK: - Child environment

enum ChildEnvironment {
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Selected Node and omp directories first (so `#!/usr/bin/env node` wrappers resolve a Node under Finder's
    /// minimal environment), then the inherited PATH entries. Empty entries dropped, duplicates keep their
    /// first position. No shell is involved and no shell startup file is read.
    static func path(nodePath: String, ompPath: String, basePath: String?) -> String {
        var entries: [String] = []
        for path in [nodePath, ompPath] where path.hasPrefix("/") {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty { entries.append(directory) }
        }
        let inherited = (basePath ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        entries += inherited.isEmpty ? fallbackPath.split(separator: ":").map(String.init) : inherited
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    static func environment(base: [String: String], nodePath: String, ompPath: String) -> [String: String] {
        var environment = base
        environment["PATH"] = path(nodePath: nodePath, ompPath: ompPath, basePath: base["PATH"])
        return environment
    }

    /// The Node whose directory goes on PATH for `#!/usr/bin/env node` wrappers: the configuration's (legacy, possibly
    /// a user Node) while its directory still exists, otherwise the managed runtime's, so a config that recorded a
    /// since-pruned managed directory never leaves wrappers without a node. The spawned executable is always managed.
    static func pathNode(configured: String, managed: String, directoryExists: (String) -> Bool) -> String {
        guard configured.hasPrefix("/") else { return managed }
        let directory = (configured as NSString).deletingLastPathComponent
        return !directory.isEmpty && directoryExists(directory) ? configured : managed
    }

    /// Existing directory (symlinks followed), as opposed to a file or nothing.
    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
