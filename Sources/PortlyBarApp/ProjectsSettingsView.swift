import PortlyBarCore
import PortlyBarRuntime
import SwiftUI

private enum ProjectSelection: Hashable {
    case project(String)
    case server(String)
}

struct ProjectsSettingsView: View {
    @EnvironmentObject private var supervisor: Supervisor
    @EnvironmentObject private var model: AppModel
    @State private var selection: ProjectSelection?
    @State private var showNewProject = false

    var body: some View {
        Group {
            if supervisor.projects.isEmpty {
                EmptyProjectsDashboard(
                    ports: supervisor.listeningPorts,
                    containers: supervisor.dockerContainers,
                    addProject: { showNewProject = true },
                    showPorts: { model.selectedSettingsTab = .ports },
                    showDocker: { model.selectedSettingsTab = .docker }
                )
            } else {
                projectsBrowser
            }
        }
        .sheet(isPresented: $showNewProject) { ProjectForm() }
        .onAppear {
            if selection == nil, let first = supervisor.projects.first { selection = .project(first.id) }
            Task { await supervisor.refreshListeningPorts() }
        }
    }

    private var projectsBrowser: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("settings.projects")
                        .font(.headline)
                    Spacer()
                    Button { showNewProject = true } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("project.add")
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                Divider()
            List(selection: $selection) {
                ForEach(supervisor.projects) { project in
                    Section {
                        ForEach(project.servers) { server in
                            Label(server.name, systemImage: "terminal")
                                .tag(ProjectSelection.server(server.id))
                        }
                    } header: {
                        Label(project.name, systemImage: project.icon)
                            .tag(ProjectSelection.project(project.id))
                            .contentShape(Rectangle())
                            .onTapGesture { selection = .project(project.id) }
                    }
                }
            }
                .listStyle(.sidebar)
            }
            .frame(width: 230)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .project(let id):
            if let project = supervisor.projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project)
            } else { ContentUnavailableView("project.not.found", systemImage: "questionmark.folder") }
        case .server(let id):
            if let pair = supervisor.projects.compactMap({ project in
                project.servers.first(where: { $0.id == id }).map { (project, $0) }
            }).first {
                ServerDetailSettingsView(project: pair.0, server: pair.1)
            } else { ContentUnavailableView("server.not.found", systemImage: "questionmark.square") }
        case nil:
            ContentUnavailableView("project.select", systemImage: "server.rack")
        }
    }
}

private struct EmptyProjectsDashboard: View {
    let ports: [ListeningPort]
    let containers: [DockerContainerStatus]
    let addProject: () -> Void
    let showPorts: () -> Void
    let showDocker: () -> Void

    private var externalPorts: Int { ports.filter { $0.ownership == .external }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero

                HStack(spacing: 0) {
                    DashboardMetric(value: ports.count, label: "dashboard.active.ports", symbol: "network", color: .cyan)
                    Divider().frame(height: 42)
                    DashboardMetric(value: externalPorts, label: "dashboard.external", symbol: "bolt.horizontal.circle.fill", color: .orange)
                    Divider().frame(height: 42)
                    DashboardMetric(value: containers.count, label: "dashboard.docker", symbol: "shippingbox.fill", color: .blue)
                }
                .padding(.vertical, 5)
                .overlay(alignment: .top) { Divider().opacity(0.55) }
                .overlay(alignment: .bottom) { Divider().opacity(0.55) }

                HStack(alignment: .top, spacing: 14) {
                    DashboardPanel(
                        title: "dashboard.detected",
                        subtitle: "dashboard.detected.help",
                        symbol: "network",
                        color: .cyan,
                        count: ports.count,
                        actionTitle: "dashboard.view.all",
                        action: showPorts
                    ) {
                        if ports.isEmpty {
                            compactEmpty(symbol: "network.slash", title: "dashboard.no.ports")
                        } else {
                            ForEach(ports.prefix(6)) { port in DetectedPortSummary(port: port) }
                        }
                    }

                    DashboardPanel(
                        title: "settings.docker",
                        subtitle: "docker.subtitle",
                        symbol: "shippingbox.fill",
                        color: .blue,
                        count: containers.count,
                        actionTitle: "docker.view.all",
                        action: showDocker
                    ) {
                        if containers.isEmpty {
                            compactEmpty(symbol: "shippingbox", title: "docker.none")
                        } else {
                            ForEach(containers.prefix(6)) { container in
                                DashboardDockerRow(container: container)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.cyan)
                    Text("dashboard.project.help")
                    Spacer()
                    Button("project.add", action: addProject).buttonStyle(.borderless)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .padding(.top, 13)
                .overlay(alignment: .top) { Divider().opacity(0.55) }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("LOCAL CONTROL PLANE")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .tracking(1.2)
                Text("dashboard.welcome")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("dashboard.subtitle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("SYSTEM ONLINE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button(action: addProject) {
                    Label("project.add", systemImage: "plus")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
    }

    private func compactEmpty(symbol: String, title: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }
}

private struct DashboardMetric: View {
    let value: Int
    let label: LocalizedStringKey
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(value, format: .number)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}

private struct DashboardPanel<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let color: Color
    let count: Int
    let actionTitle: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 13, weight: .bold))
                        Text(verbatim: String(count))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(13)
            Divider().opacity(0.65)
            VStack(spacing: 0) { content }
        }
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct DetectedPortSummary: View {
    let port: ListeningPort
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: ":\(port.port)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(port.command).font(.system(size: 12, weight: .semibold))
                    Text(verbatim: "PID \(port.pid)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(shortPath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(hovering ? Color.cyan.opacity(0.08) : Color.clear)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { Divider().opacity(0.28).padding(.leading, 72) }
    }

    private var shortPath: String {
        guard let path = port.workingDirectory else {
            return String(format: String(localized: "dashboard.pid"), port.pid)
        }
        let components = URL(fileURLWithPath: path).pathComponents
        return components.suffix(4).joined(separator: "/")
    }
}

private struct DashboardDockerRow: View {
    let container: DockerContainerStatus
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(containerContext)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(verbatim: container.publishedPorts.map { ":\($0)" }.joined(separator: " "))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.blue)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(hovering ? Color.blue.opacity(0.08) : Color.clear)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { Divider().opacity(0.28).padding(.leading, 28) }
    }

    private var containerContext: String {
        if let project = container.project, let service = container.service {
            return "\(project) / \(service)"
        }
        return container.project ?? container.image
    }
}

private struct ProjectDetailView: View {
    @EnvironmentObject private var supervisor: Supervisor
    let project: ProjectConfiguration
    @State private var draftName: String
    @State private var draftRoot: String
    @State private var draftIcon: String
    @State private var draftColor: Color
    @State private var memoryMode: MemoryLimitMode
    @State private var memoryValue: String
    @State private var showNewServer = false
    @State private var showDelete = false
    @State private var errorMessage: String?

    init(project: ProjectConfiguration) {
        self.project = project
        _draftName = State(initialValue: project.name)
        _draftRoot = State(initialValue: project.root)
        _draftIcon = State(initialValue: project.icon)
        _draftColor = State(initialValue: Color(hex: project.color))
        _memoryMode = State(initialValue: project.memoryLimitMode)
        _memoryValue = State(initialValue: project.memoryLimitBytes.map(String.init) ?? "")
    }

    var body: some View {
        Form {
            Section("project.identity") {
                TextField("project.name", text: $draftName)
                TextField("project.path", text: $draftRoot)
                TextField("project.symbol", text: $draftIcon)
                ColorPicker("project.color", selection: $draftColor, supportsOpacity: false)
            }
            Section("project.memory") {
                Picker("memory.policy", selection: $memoryMode) {
                    Text("memory.inherit").tag(MemoryLimitMode.inherit)
                    Text("memory.off").tag(MemoryLimitMode.disabled)
                    Text("memory.custom").tag(MemoryLimitMode.custom)
                }
                if memoryMode == .custom {
                    TextField("memory.value", text: $memoryValue)
                        .help("memory.value.help")
                }
            }
            Section("project.servers") {
                if project.servers.isEmpty { Text("server.none").foregroundStyle(.secondary) }
                ForEach(project.servers) { server in
                    HStack {
                        StatusDot(state: supervisor.runtime(id: server.id)?.state ?? .stopped)
                        Text(server.name)
                        Spacer()
                        Text(server.port.map { ":\($0)" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Button { showNewServer = true } label: { Label("server.add", systemImage: "plus") }
            }
            Section {
                HStack {
                    Button("common.save") { save() }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("project.delete", role: .destructive) { showDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .sheet(isPresented: $showNewServer) { ServerForm(project: project) }
        .confirmationDialog("project.delete.confirm", isPresented: $showDelete) {
            Button("project.delete", role: .destructive) {
                do { try supervisor.removeProject(project.id) } catch { errorMessage = error.localizedDescription }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .errorAlert(message: $errorMessage)
    }

    private func save() {
        var updated = project
        updated.name = draftName
        updated.root = draftRoot
        updated.icon = draftIcon
        updated.color = draftColor.hexRGB
        updated.memoryLimitMode = memoryMode
        updated.memoryLimitBytes = memoryMode == .custom ? MemorySize.parse(memoryValue) : nil
        do { try supervisor.updateProject(updated) } catch { errorMessage = error.localizedDescription }
    }
}

private struct ServerDetailSettingsView: View {
    @EnvironmentObject private var supervisor: Supervisor
    @EnvironmentObject private var model: AppModel
    let project: ProjectConfiguration
    let server: ServerConfiguration
    @State private var name: String
    @State private var command: String
    @State private var port: String
    @State private var directory: String
    @State private var healthURL: String
    @State private var healthStatus: String
    @State private var environment: String
    @State private var autoRestart: Bool
    @State private var showDelete = false
    @State private var errorMessage: String?

    init(project: ProjectConfiguration, server: ServerConfiguration) {
        self.project = project
        self.server = server
        _name = State(initialValue: server.name)
        _command = State(initialValue: server.command)
        _port = State(initialValue: server.port.map(String.init) ?? "")
        _directory = State(initialValue: server.directory ?? "")
        _healthURL = State(initialValue: server.healthURL ?? "")
        _healthStatus = State(initialValue: server.expectedHealthStatus.map(String.init) ?? "")
        _environment = State(initialValue: server.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _autoRestart = State(initialValue: server.autoRestart)
    }

    var body: some View {
        Form {
            Section("server.command") {
                TextField("server.name", text: $name)
                TextField("server.command.value", text: $command)
                TextField("server.directory", text: $directory)
                TextField("server.port", text: $port)
            }
            Section("server.health") {
                TextField("server.health.url", text: $healthURL)
                TextField("server.health.status", text: $healthStatus)
                Toggle("server.auto.restart", isOn: $autoRestart)
            }
            Section("server.environment") {
                TextEditor(text: $environment)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                Text("server.environment.warning").font(.caption).foregroundStyle(.orange)
            }
            Section {
                HStack {
                    Button("common.save", action: save).keyboardShortcut(.defaultAction)
                    Button("settings.logs") { model.openSettings(tab: .logs, serverID: server.id) }
                    Spacer()
                    Button("server.delete", role: .destructive) { showDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(project.name) / \(server.name)")
        .disabled(supervisor.runtime(id: server.id)?.status.pid != nil)
        .overlay(alignment: .topTrailing) {
            if supervisor.runtime(id: server.id)?.status.pid != nil {
                Label("server.stop.to.edit", systemImage: "lock.fill")
                    .font(.caption).padding(10)
            }
        }
        .confirmationDialog("server.delete.confirm", isPresented: $showDelete) {
            Button("server.delete", role: .destructive) {
                do { try supervisor.removeServer("\(project.name)/\(server.name)") } catch { errorMessage = error.localizedDescription }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .errorAlert(message: $errorMessage)
    }

    private func save() {
        do {
            var updated = server
            updated.name = name
            updated.command = command
            updated.port = port.isEmpty ? nil : Int(port)
            updated.directory = directory.isEmpty ? nil : directory
            updated.healthURL = healthURL.isEmpty ? nil : healthURL
            updated.expectedHealthStatus = healthStatus.isEmpty ? nil : Int(healthStatus)
            updated.environment = try parseEnvironmentLines(environment)
            updated.autoRestart = autoRestart
            try supervisor.updateServer(project: project.id, server: updated)
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ProjectForm: View {
    @EnvironmentObject private var supervisor: Supervisor
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var root = ""
    @State private var icon = "shippingbox"
    @State private var color = Color.accentColor
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("project.name", text: $name)
                HStack {
                    TextField("project.path", text: $root)
                    Button("common.choose") { chooseDirectory() }
                }
                TextField("project.symbol", text: $icon)
                ColorPicker("project.color", selection: $color, supportsOpacity: false)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                Button("project.add") { save() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || root.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 300)
        .errorAlert(message: $errorMessage)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { root = panel.url?.path ?? root }
    }
    private func save() {
        do {
            try supervisor.addProject(ProjectConfiguration(name: name, root: root, icon: icon, color: color.hexRGB))
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ServerForm: View {
    @EnvironmentObject private var supervisor: Supervisor
    @Environment(\.dismiss) private var dismiss
    let project: ProjectConfiguration
    @State private var name = "dev"
    @State private var command = ""
    @State private var port = ""
    @State private var directory = ""
    @State private var start = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("server.name", text: $name)
                TextField("server.command.value", text: $command)
                TextField("server.port", text: $port)
                TextField("server.directory", text: $directory)
                Toggle("server.start.now", isOn: $start)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                Button("server.add") { save() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || command.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 330)
        .errorAlert(message: $errorMessage)
    }

    private func save() {
        do {
            let server = ServerConfiguration(
                name: name,
                command: command,
                port: port.isEmpty ? nil : Int(port),
                directory: directory.isEmpty ? nil : directory
            )
            try supervisor.addServer(project: project.id, server: server, start: start)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private func parseEnvironmentLines(_ raw: String) throws -> [String: String] {
    var result: [String: String] = [:]
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let separator = line.firstIndex(of: "="), separator != line.startIndex else {
            throw NSError(domain: "PortlyBarForm", code: 1, userInfo: [NSLocalizedDescriptionKey: "Environment entries must use KEY=VALUE: \(line)"])
        }
        result[String(line[..<separator])] = String(line[line.index(after: separator)...])
    }
    return result
}

private extension Color {
    var hexRGB: String {
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return "#0A84FF" }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}

extension View {
    func errorAlert(message: Binding<String?>) -> some View {
        alert("common.error", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("common.ok", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
