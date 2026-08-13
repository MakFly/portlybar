import AppKit
import PortlyBarRuntime
import SwiftUI

@main
struct PortlyBarApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Settings {
            SettingsRootView()
                .environmentObject(model)
                .environmentObject(model.supervisor)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("updates.check") { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.isConfigured)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlServer?
    private var configWatcher: ConfigFileWatcher?
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel.shared
        let settingsController = SettingsWindowController(model: model)
        settingsWindowController = settingsController
        statusBarController = StatusBarController(model: model)
        SettingsBridge.open = { [weak settingsController] in settingsController?.show() }
        let server = ControlServer(
            supervisor: model.supervisor,
            port: model.supervisor.configuration.apiPort,
            openSettings: { model.openSettings(tab: .projects) },
            quitApplication: { NSApp.terminate(nil) }
        )
        do {
            try server.start()
            controlServer = server
            let watcher = ConfigFileWatcher(configFile: model.supervisor.store.url) {
                Task { @MainActor in
                    do { try AppModel.shared.supervisor.reloadConfiguration() }
                    catch { AppModel.shared.supervisor.record(error: error) }
                }
            }
            try watcher.start()
            configWatcher = watcher
            do {
                let syncReport = try AgentSetupManager.synchronize()
                if !syncReport.conflicts.isEmpty {
                    model.supervisor.record(error: NSError(
                        domain: "PortlyBarAgents",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: syncReport.summary]
                    ))
                }
            } catch {
                model.supervisor.record(error: error)
            }
        } catch {
            model.supervisor.stopAll()
            let alert = NSAlert(error: error)
            alert.messageText = NSLocalizedString("api.start.failed", comment: "")
            alert.runModal()
        }
        model.restoreLoginSessionIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let supervisor = AppModel.shared.supervisor
        if supervisor.hasActiveProcesses {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("quit.confirm.title", comment: "")
            let affected = supervisor.activeSelectors().joined(separator: "\n")
            alert.informativeText = String(format: NSLocalizedString("quit.confirm.message", comment: ""), affected)
            alert.addButton(withTitle: NSLocalizedString("quit.stop", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("common.cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        supervisor.terminateEverythingSynchronously()
        configWatcher?.stop()
        controlServer?.stop()
        statusBarController = nil
        settingsWindowController = nil
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
