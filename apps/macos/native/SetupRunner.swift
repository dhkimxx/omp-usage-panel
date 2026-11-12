import Foundation
import Darwin

/// Runs the bundled `setup-install.mjs` (one JSON request on stdin, one JSON line on stdout) and bounded
/// `node --version` probes, always off the main thread. Output is capped, stderr is drained and discarded (it is
/// never shown), the working directory is `/` so a mounted DMG is never held busy, and nothing runs through a shell.
final class SetupRunner {
    /// Install is never killed: this is only how long it runs before the UI is told it is taking longer than usual.
    static let installNoticeDelay: TimeInterval = 180
    static let launchTimeout: TimeInterval = 45
    static let probeTimeout: TimeInterval = 5
    private static let outputLimit = 1 << 20
    private static let terminationGrace: TimeInterval = 5

    private let lock = NSLock()
    private var probes: Set<ObjectIdentifier> = []
    private var running: [ObjectIdentifier: Process] = [:]
    private var closed = false

    private struct Outcome { let status: Int32?; let stdout: Data; let timedOut: Bool }

    // MARK: Helper protocol

    /// `completion` runs on the main queue exactly once. `install` is a mutating transaction: it is never signalled,
    /// the call waits for the helper's real exit however long it takes, and `timeout` only schedules one
    /// `onStillRunning` notice on the main queue. `launch` is bounded: after `timeout` it is terminated and fails.
    func run(command: SetupCommand, nodePath: String, ompPath: String, helperPath: String, request: SetupRequest,
             timeout: TimeInterval, onStillRunning: (() -> Void)? = nil, completion: @escaping (Result<SetupSuccess, SetupFailure>) -> Void) {
        func finish(_ result: Result<SetupSuccess, SetupFailure>) { DispatchQueue.main.async { completion(result) } }
        guard FileManager.default.isReadableFile(atPath: helperPath) else { finish(.failure(SetupFailure(code: "missing-helper"))); return }
        guard let input = try? request.encoded() else { finish(.failure(SetupFailure(code: "invalid-request"))); return }
        let environment = ChildEnvironment.environment(base: ProcessInfo.processInfo.environment, nodePath: nodePath, ompPath: ompPath)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let outcome = execute(executable: nodePath, arguments: [helperPath, command.rawValue], input: input,
                                        environment: environment, timeout: timeout, cancellable: false, killOnTimeout: command != .install,
                                        onTimeout: { DispatchQueue.main.async { onStillRunning?() } }) else {
                finish(.failure(SetupFailure(code: "node-unavailable"))); return
            }
            if outcome.timedOut { finish(.failure(SetupFailure(code: "timeout"))); return }
            guard let status = outcome.status else { finish(.failure(SetupFailure(code: "invalid-response"))); return }
            finish(SetupResponse.parse(stdout: outcome.stdout, exitStatus: status, command: command))
        }
    }

    /// Bounded `node --version`. `completion` runs on the main queue.
    func probeNode(path: String, completion: @escaping (SetupNodeProbe) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let probe = probeNodeBlocking(path: path)
            DispatchQueue.main.async { completion(probe) }
        }
    }

    /// Blocking variant for callers already off the main thread (sequential discovery).
    func probeNodeBlocking(path: String) -> SetupNodeProbe {
        guard path.hasPrefix("/"), case .file(true) = SetupFileKind.inspect(path) else { return .notRunnable }
        let environment = ChildEnvironment.environment(base: ProcessInfo.processInfo.environment, nodePath: path, ompPath: "")
        guard let outcome = execute(executable: path, arguments: ["--version"], input: nil, environment: environment,
                                    timeout: Self.probeTimeout, cancellable: true, killOnTimeout: true, onTimeout: {}), !outcome.timedOut else { return .notRunnable }
        return SetupNodeProbe.classify(exitStatus: outcome.status, output: String(decoding: outcome.stdout, as: UTF8.self))
    }

    /// Cancels probes only. A running install is never interrupted: the window holds quit until it finishes.
    func shutdown() {
        lock.lock(); closed = true
        let cancellable = probes.compactMap { running[$0] }
        lock.unlock()
        for task in cancellable where task.isRunning { kill(task.processIdentifier, SIGKILL) }
    }

    // MARK: Execution

    private func execute(executable: String, arguments: [String], input: Data?, environment: [String: String],
                         timeout: TimeInterval, cancellable: Bool, killOnTimeout: Bool, onTimeout: () -> Void) -> Outcome? {
        lock.lock(); let isClosed = closed; lock.unlock()
        if isClosed && cancellable { return Outcome(status: nil, stdout: Data(), timedOut: true) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = environment
        task.currentDirectoryURL = URL(fileURLWithPath: "/")
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch { return nil }
        let id = ObjectIdentifier(task)
        lock.lock(); running[id] = task; if cancellable { probes.insert(id) }; lock.unlock()
        defer { lock.lock(); running[id] = nil; probes.remove(id); lock.unlock() }

        let readers = DispatchGroup()
        let collected = NSLock()
        var out = Data()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stdout.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected.lock(); if out.count < Self.outputLimit { out.append(chunk.prefix(Self.outputLimit - out.count)) }; collected.unlock()
            }
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stderr.fileHandleForReading
            while !handle.availableData.isEmpty {}
            readers.leave()
        }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut, !killOnTimeout {
            onTimeout()
            exited.wait()
        } else if task.isRunning {
            timedOut = true
            task.terminate()
            if exited.wait(timeout: .now() + Self.terminationGrace) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + Self.terminationGrace)
            }
        }
        // A descendant may keep the pipes open after the process exits; never wait on it indefinitely.
        _ = readers.wait(timeout: .now() + Self.terminationGrace)
        collected.lock(); let data = out; collected.unlock()
        return Outcome(status: task.isRunning ? nil : task.terminationStatus, stdout: data, timedOut: timedOut)
    }
}
