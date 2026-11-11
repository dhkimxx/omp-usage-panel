import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController?
    // One updater for the whole app lifetime; usage configuration changes never recreate it.
    private var updater: UpdaterCoordinator?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/omp-usage-panel/config.json").path
        let configPath: String
        if args.count == 1 { configPath = defaultPath }
        else if args.count == 3 && args[1] == "--config" { configPath = args[2] }
        else { fail("Usage: OMPUsagePanel [--config path]"); return }
        do {
            let configStore = try PanelConfigStore(configPath: configPath)
            let coordinator = UpdaterCoordinator(config: configStore.config, configPath: configStore.configPath)
            let panel = PanelController(configStore: configStore, updater: coordinator)
            updater = coordinator; controller = panel
            panel.start()
            // A just-installed update is acknowledged on every launch, only after the configuration loaded and the
            // controller started, and before the updater starts. It runs off the main thread and is never delayed.
            coordinator.acknowledgeStartup()
            coordinator.start()
        } catch { fail("Cannot load panel configuration: \(error.localizedDescription)") }
    }
    // The coordinator may hold a quit while a withdrawn, uncancelable extraction resolves, so an armed update can
    // never install on that quit. Its normal authorized restart and every other quit proceed immediately.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updater?.applicationShouldTerminate() ?? .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop(); updater?.stop() }
    private func fail(_ message: String) {
        let alert = NSAlert(); alert.messageText = "OMP Usage Panel"; alert.informativeText = message; alert.runModal(); NSApp.terminate(nil)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
