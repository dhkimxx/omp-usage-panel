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
            let configStore = try PanelConfigStore(configPath: configPath)
            controller = PanelController(configStore: configStore); controller?.start()
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
