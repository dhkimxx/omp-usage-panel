import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController?
    // One updater for the whole app lifetime; usage configuration changes never recreate it.
    private var updater: UpdaterCoordinator?
    // First-run setup (and the managed-launch handoff) never creates the panel or the updater.
    private var setup: SetupWindowController?
    private let setupRunner = SetupRunner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch SetupLaunch.route(arguments: CommandLine.arguments, bundlePath: Bundle.main.bundlePath, home: home, resolve: SetupLaunch.resolvingSymlinks) {
        case .normal(let configPath): startPanel(configPath: configPath)
        case .usage: fail("Usage: OMPUsagePanel [--config path]")
        case .setup: showSetup(home: home, notice: nil)
        case .managedHandoff: handOff(home: home)
        }
    }

    private func startPanel(configPath: String) {
        do {
            let configStore = try PanelConfigStore(configPath: configPath)
            let coordinator = UpdaterCoordinator(configPath: configStore.configPath)
            let panel = PanelController(configStore: configStore, updater: coordinator)
            updater = coordinator; controller = panel
            panel.start()
            // A just-installed update is acknowledged on every launch, only after the configuration loaded and the
            // controller started, and before the updater starts. It runs off the main thread and is never delayed.
            coordinator.acknowledgeStartup()
            coordinator.start()
        } catch { fail("Cannot load panel configuration: \(error.localizedDescription)") }
    }

    private var helperPath: String { Bundle.main.resourceURL?.appendingPathComponent(SetupLaunch.helperRelativePath).path ?? "" }

    private func showSetup(home: String, notice: String?) {
        // A regular app gets a Dock icon and menu bar for the one-time setup window; this process then exits.
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        let window = SetupWindowController(home: home, sourceAppPath: Bundle.main.bundlePath, helperPath: helperPath, runner: setupRunner, notice: notice)
        setup = window
        window.present()
    }

    /// No-argument launch of the managed canonical app: the bundled helper verifies the managed identity and starts,
    /// activates or continues as the single registered job. The panel is never started here unless the helper
    /// reports that this very process is the job host.
    private func handOff(home: String) {
        let configPath = SetupLaunch.defaultConfigPath(home: home)
        let existing = SetupExistingConfig.read(path: configPath)
        guard case .valid(let config) = existing else {
            showSetup(home: home, notice: existing == .none ? "OMP Usage is not set up for this account yet." : "OMP Usage could not start from its saved configuration. Review the details below.")
            return
        }
        let request = SetupRequest(sourceAppPath: Bundle.main.bundlePath, hostPid: Int(ProcessInfo.processInfo.processIdentifier), ompPath: nil, profile: nil)
        // The bundled Node is resolved (and extracted on first use) off the main thread inside the runner.
        setupRunner.run(command: .launch, ompPath: config.ompPath, helperPath: helperPath, request: request, timeout: SetupRunner.launchTimeout) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let success):
                switch success.action {
                case .relaunch: NSApp.terminate(nil)
                case .activate:
                    if let pid = success.pid { NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: []) }
                    NSApp.terminate(nil)
                case .continue: self.startPanel(configPath: success.configPath)
                }
            case .failure(let failure):
                self.showSetup(home: home, notice: failure.userMessage)
            }
        }
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit OMP Usage Setup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
    }

    // The coordinator may hold a quit while a withdrawn, uncancelable extraction resolves, so an armed update can
    // never install on that quit. Its normal authorized restart and every other quit proceed immediately. Setup
    // holds a quit only while its install helper is mutating.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let setup { return setup.applicationShouldTerminate() }
        return updater?.applicationShouldTerminate() ?? .terminateNow
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
