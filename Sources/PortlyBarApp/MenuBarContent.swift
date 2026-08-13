import AppKit
import PortlyBarCore
import PortlyBarRuntime
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: Supervisor
    @AppStorage("app.language") private var appLanguage = "en"
    @State private var showStopAllConfirmation = false
    @State private var portPendingStop: ListeningPort?
    @State private var showStoppedContainers = false
    @State private var showAllPorts = false
    @State private var showAllContainers = false
    @State private var errorMessage: String?

    private let maximumVisiblePorts = 6
    private let maximumVisibleContainers = 5

    private var visiblePorts: [ListeningPort] {
        showAllPorts ? supervisor.listeningPorts : Array(supervisor.listeningPorts.prefix(maximumVisiblePorts))
    }
    private var visibleRunningContainers: [DockerContainerStatus] {
        let all = supervisor.runningDockerContainers
        return showAllContainers ? all : Array(all.prefix(maximumVisibleContainers))
    }
    private var visibleStoppedContainers: [DockerContainerStatus] {
        let all = supervisor.stoppedDockerContainers
        return showAllContainers ? all : Array(all.prefix(maximumVisibleContainers))
    }

    private var isExpanded: Bool { showAllPorts || showAllContainers || showStoppedContainers }

    private var contentHeight: CGFloat {
        let projectRows = supervisor.projects.count + supervisor.projects.reduce(0) { $0 + $1.servers.count }
        let portRows = visiblePorts.count
        var dockerRows = visibleRunningContainers.count
        if !supervisor.stoppedDockerContainers.isEmpty {
            dockerRows += 1
            if showStoppedContainers { dockerRows += visibleStoppedContainers.count }
        }
        let sections = [projectRows, portRows, dockerRows].filter { $0 > 0 }.count
        let rows = CGFloat(projectRows + portRows + dockerRows) * 42 + CGFloat(sections) * 34 + 20
        return min(isExpanded ? 620 : 500, max(210, rows))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            if hasContent {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(supervisor.projects) { project in projectSection(project) }
                        if !supervisor.listeningPorts.isEmpty { detectedPortsSection }
                        if !supervisor.dockerContainers.isEmpty { dockerSection }
                        if !supervisor.temporaryStatuses.isEmpty { temporarySection }
                    }
                    .padding(10)
                }
                .frame(height: contentHeight)
            } else {
                emptyState
            }

            footer
        }
        .frame(width: 404)
        .background(.ultraThickMaterial)
        .environment(\.locale, Locale(identifier: appLanguage))
        .onAppear {
            Task { await supervisor.refreshListeningPorts() }
        }
        .confirmationDialog("stop.all.confirm", isPresented: $showStopAllConfirmation) {
            Button("stop.all", role: .destructive) { supervisor.stopAll() }
            Button("common.cancel", role: .cancel) {}
        }
        .confirmationDialog("port.stop.confirm", isPresented: stopPortDialogPresented) {
            Button("port.stop", role: .destructive) {
                if let port = portPendingStop { stopExternal(port) }
            }
            Button("common.cancel", role: .cancel) { portPendingStop = nil }
        } message: {
            if let port = portPendingStop {
                Text(verbatim: "\(port.command) · PID \(port.pid) · :\(port.port)")
            }
        }
        .errorAlert(message: $errorMessage)
    }

    private var stopPortDialogPresented: Binding<Bool> {
        Binding(get: { portPendingStop != nil }, set: { if !$0 { portPendingStop = nil } })
    }

    private func stopExternal(_ port: ListeningPort) {
        do {
            try supervisor.stopExternalPort(
                PortRequest(port: port.port, expectedPID: port.pid, force: false, confirmed: true)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        portPendingStop = nil
    }

    private func setDockerContainer(_ container: DockerContainerStatus, running: Bool) {
        Task {
            do {
                if running {
                    try await supervisor.startDockerContainer(id: container.id, name: container.name)
                } else {
                    try await supervisor.stopDockerContainer(id: container.id, name: container.name)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var hasContent: Bool {
        !supervisor.projects.isEmpty || !supervisor.listeningPorts.isEmpty
            || !supervisor.dockerContainers.isEmpty || !supervisor.temporaryStatuses.isEmpty
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("PortlyBar")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("menu.subtitle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(supervisor.hasProblems ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(headerStatus)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.10), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var headerStatus: String {
        if supervisor.runningCount > 0 { return "\(supervisor.runningCount) RUNNING" }
        return "\(supervisor.listeningPorts.count) PORTS"
    }

    private func projectSection(_ project: ProjectConfiguration) -> some View {
        MenuSurface {
            sectionHeader(
                title: project.name,
                symbol: project.icon,
                count: project.servers.count,
                color: Color(hex: project.color)
            ) {
                HStack(spacing: 4) {
                    CompactIconButton(symbol: "play.fill", help: "project.start") {
                        try? supervisor.start(project: project.id)
                    }
                    CompactIconButton(symbol: "stop.fill", help: "project.stop") {
                        try? supervisor.stop(project: project.id)
                    }
                }
            }

            ForEach(project.servers) { server in
                if let runtime = supervisor.runtime(id: server.id) {
                    MenuServerRow(runtime: runtime) {
                        model.openSettings(tab: .logs, serverID: server.id)
                    }
                }
            }
        }
    }

    private var detectedPortsSection: some View {
        MenuSurface {
            sectionHeader(
                title: String(localized: "dashboard.detected"),
                symbol: "network",
                count: supervisor.listeningPorts.count,
                color: .cyan
            ) {
                SectionExpander(
                    isExpanded: $showAllPorts,
                    hiddenCount: supervisor.listeningPorts.count - visiblePorts.count
                )
            }

            ForEach(visiblePorts) { port in
                DiscoveredPortRow(port: port) {
                    if let id = port.managedServerID {
                        supervisor.runtime(id: id)?.stop()
                    } else {
                        portPendingStop = port
                    }
                }
            }
        }
    }

    private var dockerSection: some View {
        MenuSurface {
            sectionHeader(
                title: "Docker",
                symbol: "shippingbox.fill",
                count: supervisor.runningDockerContainers.count,
                color: .blue
            ) {
                SectionExpander(
                    isExpanded: $showAllContainers,
                    hiddenCount: hiddenContainerCount
                )
            }

            ForEach(visibleRunningContainers) { container in
                DockerContainerMenuRow(container: container) {
                    setDockerContainer(container, running: false)
                }
            }

            if !supervisor.stoppedDockerContainers.isEmpty { stoppedContainersGroup }
        }
    }

    /// Rows the Docker section is currently hiding. Stopped rows only count once
    /// their group is open, since the group header already advertises its total.
    private var hiddenContainerCount: Int {
        let running = supervisor.runningDockerContainers.count - visibleRunningContainers.count
        guard showStoppedContainers else { return running }
        return running + supervisor.stoppedDockerContainers.count - visibleStoppedContainers.count
    }

    @ViewBuilder private var stoppedContainersGroup: some View {
        DisclosureToggle(
            isExpanded: $showStoppedContainers,
            count: supervisor.stoppedDockerContainers.count
        )

        if showStoppedContainers {
            ForEach(visibleStoppedContainers) { container in
                DockerContainerMenuRow(container: container) {
                    setDockerContainer(container, running: true)
                }
            }
        }
    }

    private var temporarySection: some View {
        MenuSurface {
            sectionHeader(
                title: String(localized: "temporary.title"),
                symbol: "timer",
                count: supervisor.temporaryStatuses.count,
                color: .orange
            ) { EmptyView() }

            ForEach(supervisor.temporaryStatuses) { job in
                HStack(spacing: 10) {
                    StatusDot(state: job.state == .running ? .running : (job.state == .failed || job.state == .timedOut ? .failed : .stopped))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.name).fontWeight(.medium).lineLimit(1)
                        Text(job.state.rawValue.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if job.state == .running {
                        CompactIconButton(symbol: "stop.fill", help: "server.stop") {
                            supervisor.runtime(id: job.id)?.stop()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private func sectionHeader<Accessory: View>(
        title: String,
        symbol: String,
        count: Int,
        color: Color,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(verbatim: title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Text(verbatim: String(count))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 5)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("dashboard.no.ports").font(.headline)
            Text("dashboard.no.ports.help")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("project.add") { model.openSettings(tab: .projects) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            MenuFooterButton(title: "settings.ports", symbol: "network") {
                model.openSettings(tab: .ports)
            }
            MenuFooterButton(title: "Docker", symbol: "shippingbox") {
                model.openSettings(tab: .docker)
            }
            MenuFooterButton(title: "settings.open", symbol: "gearshape") {
                model.openSettings(tab: .projects)
            }
            Spacer(minLength: 8)
            MenuFooterButton(title: "stop.all", symbol: "stop.fill", role: .destructive) {
                showStopAllConfirmation = true
            }
            .disabled(!supervisor.hasActiveProcesses)
            MenuFooterButton(title: "common.quit", symbol: "power", role: .destructive) {
                NSApp.terminate(nil)
            }
        }
        .padding(7)
        .background(Color.black.opacity(0.09))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct MenuSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

private struct DiscoveredPortRow: View {
    let port: ListeningPort
    let onStop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text(verbatim: ":\(port.port)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(port.command).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let directory = port.workingDirectory {
                    Text(directory)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            stopControl
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hovering ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 3)
        .onHover { hovering = $0 }
        .onTapGesture {
            NSWorkspace.shared.open(URL(string: "http://localhost:\(port.port)")!)
        }
    }

    @ViewBuilder private var stopControl: some View {
        switch port.ownership {
        case .managed:
            CompactIconButton(symbol: "stop.fill", help: "server.stop", action: onStop)
        case .external:
            CompactIconButton(symbol: "stop.fill", help: "port.stop", tint: .red, action: onStop)
        case .protected:
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
                .help("ownership.protected")
        }
    }
}

private struct DockerContainerMenuRow: View {
    let container: DockerContainerStatus
    let onToggle: () -> Void
    @State private var hovering = false

    private var isRunning: Bool { container.state.isRunning }

    private var stateColor: Color {
        switch container.state {
        case .running: return .green
        case .paused, .restarting: return .blue
        case .dead: return .red
        case .created, .exited, .unknown: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(container.project ?? container.image)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .opacity(isRunning ? 1 : 0.55)
            Spacer()
            if isRunning, !container.publishedPorts.isEmpty {
                Text(verbatim: container.publishedPorts.map { ":\($0)" }.joined(separator: "  "))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
            } else {
                Text(isRunning ? "docker.internal" : "docker.state.stopped")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            CompactIconButton(
                symbol: isRunning ? "stop.fill" : "play.fill",
                help: isRunning ? "docker.stop" : "docker.start",
                action: onToggle
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hovering ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 3)
        .onHover { hovering = $0 }
    }
}

/// Section header accessory that reveals the rows a section is truncating,
/// inside the popover. Stays out of the way when nothing is hidden.
private struct SectionExpander: View {
    @Binding var isExpanded: Bool
    let hiddenCount: Int
    @State private var hovering = false

    var body: some View {
        if isExpanded || hiddenCount > 0 {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    if isExpanded {
                        Text("menu.show.less")
                    } else {
                        Text("menu.show.all")
                        Text(verbatim: "+\(hiddenCount)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(hovering ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

private struct DisclosureToggle: View {
    @Binding var isExpanded: Bool
    let count: Int
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 7)
                Text("docker.stopped.section")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: String(count))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 3)
        .onHover { hovering = $0 }
    }
}

private struct MenuFooterButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct CompactIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: 22, height: 22)
                .background(hovering ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct MenuServerRow: View {
    @ObservedObject var runtime: ServerRuntime
    let openLogs: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(state: runtime.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(runtime.configuration.name).fontWeight(.medium).lineLimit(1)
                if let error = runtime.lastError {
                    Text(error).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            if let port = runtime.configuration.port {
                Text(verbatim: ":\(port)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
            Spacer()
            CompactIconButton(symbol: runtime.status.pid == nil ? "play.fill" : "stop.fill", help: "server.stop") {
                if runtime.status.pid == nil { runtime.start() } else { runtime.stop() }
            }
            CompactIconButton(symbol: "arrow.clockwise", help: "server.auto.restart") { runtime.restart() }
                .disabled(runtime.status.pid == nil)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hovering ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 3)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: openLogs)
    }
}

struct StatusDot: View {
    let state: ServerState
    private var color: Color {
        switch state {
        case .running: return .green
        case .starting, .stopping: return .blue
        case .unhealthy: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay {
                if state == .starting || state == .stopping {
                    Circle().stroke(color.opacity(0.35), lineWidth: 4).scaleEffect(1.5)
                }
            }
            .accessibilityLabel(Text(state.rawValue))
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x0A84FF
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
