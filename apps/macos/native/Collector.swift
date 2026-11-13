import Foundation
import Darwin

final class Collector {
    private var process: Process?
    private var resolvingNode = false
    private var ownedGroup: pid_t?
    private var pendingForce = false
    private var stopped = false
    private let configPath: String
    private let config: PanelConfig
    // Finder launches with a minimal PATH, so `#!/usr/bin/env node` omp wrappers need a Node directory and the omp
    // directory first. The collector itself always runs the bundled Node; `config.nodePath` (legacy) only contributes
    // its directory to the PATH while that directory still exists, else the managed Node's directory is used.
    // The config is immutable for this collector's lifetime (changes replace it); no shell is used.
    var completion: ((Result<PanelResult, Error>) -> Void)?

    init(configPath: String, config: PanelConfig) {
        self.configPath = configPath; self.config = config
    }
    func collect(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped else { return }
        if process != nil || resolvingNode { pendingForce = pendingForce || force; return }
        resolvingNode = true
        // The first run extracts the bundled Node (seconds), so resolution never happens on the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let node = ManagedNode.ensure(bundle: .main)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.resolvingNode = false
                guard !self.stopped else { return }
                let wantsForce = self.pendingForce || force
                self.pendingForce = false
                switch node {
                case .success(let path): self.launch(node: path, force: wantsForce)
                case .failure(let error): self.completion?(.failure(CollectorError(message: error.userMessage)))
                }
            }
        }
    }
    private func launch(node: String, force: Bool) {
        guard let runtime = Bundle.main.resourceURL?.appendingPathComponent("runtime/apps/macos/collect.mjs").path else {
            completion?(.failure(CollectorError(message: "Bundled collector is missing"))); return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = [runtime, "--config", configPath] + (force ? ["--refresh"] : [])
        // The PATH is built per launch because the managed Node's directory is only known once it is resolved.
        let pathNode = ChildEnvironment.pathNode(configured: config.nodePath, managed: node, directoryExists: ChildEnvironment.directoryExists)
        task.environment = ChildEnvironment.environment(base: ProcessInfo.processInfo.environment, nodePath: pathNode, ompPath: config.ompPath)
        let stdout = Pipe(), stderr = Pipe()
        task.standardOutput = stdout; task.standardError = stderr
        process = task
        do { try task.run() } catch {
            process = nil; completion?(.failure(CollectorError(message: "Unable to start collector: \(error.localizedDescription)"))); return
        }
        // Foundation launches a separate process group on macOS. Verify before
        // signalling a negative PID so an unrelated group is never targeted.
        let pid = task.processIdentifier
        ownedGroup = getpgid(pid) == pid ? pid : nil
        let deadline = DispatchWorkItem { [weak self, weak task] in
            guard let self = self, let task = task, self.process === task else { return }
            self.killOwnedProcess(task)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(5, config.timeoutSeconds * 2 + 10), execute: deadline)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let group = DispatchGroup()
            let lock = NSLock()
            var out = Data(), err = Data()
            group.enter(); DispatchQueue.global(qos: .utility).async { let data = stdout.fileHandleForReading.readDataToEndOfFile(); lock.lock(); out = data; lock.unlock(); group.leave() }
            group.enter(); DispatchQueue.global(qos: .utility).async { let data = stderr.fileHandleForReading.readDataToEndOfFile(); lock.lock(); err = data; lock.unlock(); group.leave() }
            task.waitUntilExit(); group.wait()
            let result: Result<PanelResult, Error>
            if task.terminationStatus != 0 {
                // Collector stderr is intended for users, but never include arbitrary process output in the UI.
                result = .failure(CollectorError(message: "Collector failed (exit \(task.terminationStatus))"))
            } else {
                do { result = .success(try JSONDecoder().decode(PanelResult.self, from: out)) }
                catch { result = .failure(CollectorError(message: "Collector returned invalid data")) }
            }
            _ = err
            DispatchQueue.main.async {
                deadline.cancel()
                guard let self = self, self.process === task else { return }
                self.ownedGroup = nil
                self.process = nil
                guard !self.stopped else { return }
                self.completion?(result)
                if self.pendingForce { self.pendingForce = false; self.collect(force: true) }
            }
        }
    }
    private func killOwnedProcess(_ task: Process) {
        if let group = ownedGroup {
            // Kill immediately: the app can exit before delayed escalation, and
            // descendants can keep the collector pipes open after Node exits.
            kill(-group, SIGKILL)
        } else if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
        }
    }
    func stop() {
        stopped = true; pendingForce = false
        if let task = process { killOwnedProcess(task) }
    }
}
struct CollectorError: LocalizedError { let message: String; var errorDescription: String? { message } }
