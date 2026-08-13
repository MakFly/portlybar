import AppKit
import Combine
import Foundation
import PortlyBarCore
import PortlyBarRuntime
import ServiceManagement
import Sparkle
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let supervisor: Supervisor
    @Published var selectedSettingsTab: SettingsTab = .projects
    @Published var selectedLogServerID: String?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["app.language": "en"])
        let language = defaults.string(forKey: "app.language") ?? "en"
        defaults.set([language], forKey: "AppleLanguages")
        do {
            try PortlyBarPaths.ensureDirectories()
            supervisor = try Supervisor()
        } catch {
            fatalError("PortlyBar cannot initialize its configuration: \(error.localizedDescription)")
        }
        supervisor.$serverStatuses
            .map { statuses in statuses.filter { $0.pid != nil }.map(\.selector).sorted() }
            .removeDuplicates()
            .sink { selectors in
                if LoginItemController.isEnabled { try? LoginItemController.capture(selectors: selectors) }
            }
            .store(in: &cancellables)
    }

    func openSettings(tab: SettingsTab, serverID: String? = nil) {
        selectedSettingsTab = tab
        selectedLogServerID = serverID
        SettingsBridge.open?()
    }

    func restoreLoginSessionIfNeeded() {
        guard LoginItemController.isEnabled,
              let data = try? Data(contentsOf: PortlyBarPaths.resumeFile),
              let selectors = try? JSONDecoder().decode([String].self, from: data) else { return }
        supervisor.restore(selectors: selectors)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case projects
    case ports
    case docker
    case logs
    case resources
    case general

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .projects: return "settings.projects"
        case .ports: return "settings.ports"
        case .docker: return "settings.docker"
        case .logs: return "settings.logs"
        case .resources: return "settings.resources"
        case .general: return "settings.general"
        }
    }
    var symbol: String {
        switch self {
        case .projects: return "server.rack"
        case .ports: return "network"
        case .docker: return "shippingbox"
        case .logs: return "terminal"
        case .resources: return "gauge.with.dots.needle.67percent"
        case .general: return "gearshape"
        }
    }
}

@MainActor
enum SettingsBridge {
    static var open: (() -> Void)?
}

@MainActor
enum LoginItemController {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool, activeSelectors: [String]) throws {
        if enabled {
            try capture(selectors: activeSelectors)
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: PortlyBarPaths.resumeFile)
        }
    }

    static func capture(selectors: [String]) throws {
        try PortlyBarPaths.ensureDirectories()
        let data = try JSONEncoder().encode(selectors)
        try data.write(to: PortlyBarPaths.resumeFile, options: .atomic)
    }
}

final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    let isConfigured: Bool
    private var controller: SPUStandardUpdaterController?

    private override init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        isConfigured = feed?.isEmpty == false && key?.isEmpty == false
        super.init()
        if isConfigured {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
        }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller?.checkForUpdates(nil)
    }
}
