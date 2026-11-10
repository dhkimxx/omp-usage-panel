import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/omp-usage-panel/config.json").path
        let configPath: String
        if args.count == 1 { configPath = defaultPath }
        else if args.count == 3 && args[1] == "--config" { configPath = args[2] }
        else { fail("Usage: OMPUsagePanel [--config path]"); return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let config = try JSONDecoder().decode(PanelConfig.self, from: data)
            guard config.version == 1, config.nodePath.hasPrefix("/"), config.refreshSeconds.isFinite, config.refreshSeconds > 0, config.timeoutSeconds.isFinite, config.timeoutSeconds > 0 else { throw CollectorError(message: "Invalid panel configuration") }
            controller = PanelController(config: config, configPath: configPath); controller?.start()
        } catch { fail("Cannot load panel configuration: \(error.localizedDescription)") }
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
    private func fail(_ message: String) {
        let alert = NSAlert(); alert.messageText = "OMP Usage Panel"; alert.informativeText = message; alert.runModal(); NSApp.terminate(nil)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
