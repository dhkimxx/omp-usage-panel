import Foundation
import Darwin

final class Collector {
    private var process: Process?
    private var ownedGroup: pid_t?
    private var pendingForce = false
    private var stopped = false
    private let configPath: String
    private let config: PanelConfig
    var completion: ((Result<PanelResult, Error>) -> Void)?

    init(configPath: String, config: PanelConfig) { self.configPath = configPath; self.config = config }
    func collect(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped else { return }
        if process != nil { pendingForce = pendingForce || force; return }
        guard let runtime = Bundle.main.resourceURL?.appendingPathComponent("runtime/apps/macos/collect.mjs").path else {
            completion?(.failure(CollectorError(message: "Bundled collector is missing"))); return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: config.nodePath)
        task.arguments = [runtime, "--config", configPath] + (force ? ["--refresh"] : [])
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
