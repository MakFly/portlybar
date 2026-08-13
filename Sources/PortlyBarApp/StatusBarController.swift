import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var defaultsObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        configurePopover()
        configureButton()
        observeState()
        updateButton()
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configurePopover() {
        let content = MenuBarContent()
            .environmentObject(model)
            .environmentObject(model.supervisor)
        let hostingController = NSHostingController(rootView: content)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 404, height: 600)
        popover.behavior = .transient
        popover.animates = true
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "point.3.connected.trianglepath.dotted",
            accessibilityDescription: "PortlyBar"
        )
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "PortlyBar"
        button.setAccessibilityLabel("PortlyBar")
    }

    private func observeState() {
        model.supervisor.$serverStatuses
            .combineLatest(model.supervisor.$listeningPorts, model.supervisor.$dockerContainers)
            .sink { [weak self] _, _, _ in self?.updateButton() }
            .store(in: &cancellables)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateButton() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let showName = UserDefaults.standard.bool(forKey: "menuBar.showName")
        button.title = showName ? " PortlyBar" : ""
        button.imagePosition = showName ? .imageLeading : .imageOnly
        let problemSuffix = model.supervisor.hasProblems ? " — attention required" : ""
        button.toolTip = "PortlyBar — \(model.supervisor.listeningPorts.count) ports, \(model.supervisor.dockerContainers.count) Docker\(problemSuffix)"
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
