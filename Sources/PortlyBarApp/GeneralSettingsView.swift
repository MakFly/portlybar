import AppKit
import PortlyBarCore
import PortlyBarRuntime
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var supervisor: Supervisor
    @AppStorage("menuBar.showName") private var showName = false
    @AppStorage("app.language") private var appLanguage = "en"
    @State private var launchAtLogin = LoginItemController.isEnabled
    @State private var healthInterval = ""
    @State private var restartAttempts = ""
    @State private var logLines = ""
    @State private var logFileMB = ""
    @State private var notice: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("general.language") {
                Picker("general.language", selection: $appLanguage) {
                    Text("English").tag("en")
                    Text("Français").tag("fr")
                }
                .pickerStyle(.segmented)
                Text("general.language.help").font(.caption).foregroundStyle(.secondary)
            }
            Section("general.menubar") {
                Toggle("general.show.name", isOn: $showName)
                Text("general.menubar.help").font(.caption).foregroundStyle(.secondary)
            }
            Section("general.startup") {
                Toggle("general.launch.login", isOn: Binding(
                    get: { launchAtLogin },
                    set: updateLoginItem
                ))
                Text("general.restore.help").font(.caption).foregroundStyle(.secondary)
            }
            Section("general.runtime") {
                LabeledContent("general.health.interval") { TextField("10", text: $healthInterval).frame(width: 90) }
                LabeledContent("general.restart.attempts") { TextField("5", text: $restartAttempts).frame(width: 90) }
                LabeledContent("general.log.lines") { TextField("5000", text: $logLines).frame(width: 90) }
                LabeledContent("general.log.mb") { TextField("10", text: $logFileMB).frame(width: 90) }
                Button("common.save", action: saveRuntime)
            }
            Section("general.configuration") {
                LabeledContent("general.config.file") {
                    Text(PortlyBarPaths.configFile.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent("general.api") {
                    Text(verbatim: "127.0.0.1:\(supervisor.configuration.apiPort)").monospacedDigit()
                }
                Button("general.reveal.config") {
                    NSWorkspace.shared.selectFile(PortlyBarPaths.configFile.path, inFileViewerRootedAtPath: PortlyBarPaths.configDirectory.path)
                }
                Button("general.reload.config") {
                    do { try supervisor.reloadConfiguration() } catch { errorMessage = error.localizedDescription }
                }
            }
            Section("general.agents") {
                Text("general.agents.help").font(.caption).foregroundStyle(.secondary)
                Button("general.sync.skills") { synchronizeAgentSkills() }
            }
            Section("general.updates") {
                if UpdateController.shared.isConfigured {
                    Button("updates.check") { UpdateController.shared.checkForUpdates() }
                } else {
                    Label("updates.disabled", systemImage: "lock.shield")
                    Text("updates.disabled.help").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("general.about") {
                LabeledContent("general.version", value: Supervisor.version)
                LabeledContent("general.telemetry", value: String(localized: "general.telemetry.none"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("settings.general")
        .onAppear(perform: loadRuntime)
        .onChange(of: appLanguage) { _, language in
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
        .alert("common.done", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("common.ok", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .errorAlert(message: $errorMessage)
    }

    private func loadRuntime() {
        let config = supervisor.configuration
        healthInterval = String(config.healthIntervalSeconds)
        restartAttempts = String(config.maxRestartAttempts)
        logLines = String(config.logBufferLines)
        logFileMB = String(config.logFileMaxMB)
        launchAtLogin = LoginItemController.isEnabled
    }

    private func saveRuntime() {
        guard let health = Int(healthInterval), health > 0,
              let restarts = Int(restartAttempts), restarts >= 0,
              let lines = Int(logLines), lines >= 100,
              let megabytes = Int(logFileMB), megabytes > 0 else {
            errorMessage = String(localized: "general.runtime.invalid")
            return
        }
        do {
            try supervisor.updateRuntimeSettings(healthInterval: health, restartAttempts: restarts, logLines: lines, logFileMB: megabytes)
            notice = String(localized: "general.saved")
        } catch { errorMessage = error.localizedDescription }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled, activeSelectors: supervisor.activeSelectors())
            launchAtLogin = LoginItemController.isEnabled
        } catch {
            launchAtLogin = LoginItemController.isEnabled
            errorMessage = error.localizedDescription
        }
    }

    private func synchronizeAgentSkills() {
        do {
            notice = try AgentSetupManager.synchronize().summary
        } catch { errorMessage = error.localizedDescription }
    }
}

enum AgentSetupManager {
    static func synchronize() throws -> AgentSkillSyncReport {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "PortlyBarAgents", code: 1, userInfo: [NSLocalizedDescriptionKey: "The application resource directory is unavailable."])
        }
        return try AgentSkillInstaller.synchronize(
            sourceRoot: resources.appendingPathComponent("skills", isDirectory: true),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            cliExecutable: resources.appendingPathComponent("bin/portlybar")
        )
    }
}
