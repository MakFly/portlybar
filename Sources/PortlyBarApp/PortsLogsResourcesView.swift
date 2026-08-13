import AppKit
import PortlyBarCore
import PortlyBarRuntime
import SwiftTerm
import SwiftUI

struct PortsSettingsView: View {
    @EnvironmentObject private var supervisor: Supervisor
    @State private var query = ""
    @State private var selectedForStop: ListeningPort?
    @State private var forceCandidate: ListeningPort?
    @State private var errorMessage: String?

    private var ports: [ListeningPort] {
        let all = supervisor.ports()
        guard !query.isEmpty else { return all }
        return all.filter {
            String($0.port).contains(query) || $0.command.localizedCaseInsensitiveContains(query)
                || ($0.workingDirectory?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            portsHeader
            List(ports) { item in PortRow(item: item, onStop: { selectedForStop = item }) }
            .searchable(text: $query, prompt: "ports.search")
            .overlay {
                if ports.isEmpty, query.isEmpty {
                    ContentUnavailableView("dashboard.no.ports", systemImage: "network.slash", description: Text("dashboard.no.ports.help"))
                } else if ports.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .task { await supervisor.refreshListeningPorts() }
        .confirmationDialog("port.stop.confirm", isPresented: stopDialogPresented) {
            Button("port.stop", role: .destructive) {
                if let item = selectedForStop { stop(item, force: false) }
            }
            Button("common.cancel", role: .cancel) { selectedForStop = nil }
        } message: {
            if let item = selectedForStop { Text(verbatim: "\(item.command) · PID \(item.pid) · :\(item.port)") }
        }
        .confirmationDialog("port.force.confirm", isPresented: forceDialogPresented) {
            Button("port.force", role: .destructive) {
                if let item = forceCandidate { stop(item, force: true) }
            }
            Button("common.cancel", role: .cancel) { forceCandidate = nil }
        }
        .errorAlert(message: $errorMessage)
    }

    private func stop(_ item: ListeningPort, force: Bool) {
        do {
            try supervisor.stopExternalPort(PortRequest(port: item.port, expectedPID: item.pid, force: force, confirmed: true))
            selectedForStop = nil
            forceCandidate = nil
            if !force {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    if let current = supervisor.ports().first(where: { $0.port == item.port && $0.pid == item.pid }) {
                        forceCandidate = current
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private var portsHeader: some View {
        HStack {
            Text("settings.ports").font(.title2.bold())
            Spacer()
            Text(verbatim: String(ports.count)).foregroundStyle(.secondary).monospacedDigit()
            Button {
                Task { await supervisor.refreshListeningPorts() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("ports.refresh")
        }
        .padding()
    }

    private var stopDialogPresented: Binding<Bool> {
        Binding(get: { selectedForStop != nil }, set: { if !$0 { selectedForStop = nil } })
    }
    private var forceDialogPresented: Binding<Bool> {
        Binding(get: { forceCandidate != nil }, set: { if !$0 { forceCandidate = nil } })
    }
}

private struct PortRow: View {
    @EnvironmentObject private var supervisor: Supervisor
    let item: ListeningPort
    let onStop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: ":\(item.port)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.cyan)
                .frame(width: 72, alignment: .leading)
            Image(systemName: ownershipSymbol).foregroundStyle(ownershipColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.command).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(LocalizedStringKey("ownership.\(item.ownership.rawValue)"))
                .font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                .background(ownershipColor.opacity(0.12), in: Capsule())
            Button { NSWorkspace.shared.open(URL(string: "http://localhost:\(item.port)")!) } label: {
                Image(systemName: "safari")
            }
            .help("server.open.browser")
            actionButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hovering ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var actionButton: some View {
        if item.ownership == .external {
            Button(role: .destructive, action: onStop) { Image(systemName: "stop.fill") }.help("port.stop")
        } else if item.ownership == .managed, let id = item.managedServerID {
            Button { supervisor.runtime(id: id)?.stop() } label: { Image(systemName: "stop.fill") }.help("server.stop")
        } else {
            Image(systemName: "lock.fill").foregroundStyle(.tertiary).frame(width: 24)
        }
    }

    private var detail: String {
        "PID \(item.pid) · \(item.user)" + (item.workingDirectory.map { " · \($0)" } ?? "")
    }
    private var ownershipSymbol: String {
        switch item.ownership { case .managed: return "checkmark.circle.fill"; case .external: return "person.crop.circle"; case .protected: return "lock.shield" }
    }
    private var ownershipColor: SwiftUI.Color {
        switch item.ownership { case .managed: return .green; case .external: return .blue; case .protected: return .secondary }
    }
}

struct DockerSettingsView: View {
    @EnvironmentObject private var supervisor: Supervisor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.docker").font(.title2.bold())
                    Text("docker.subtitle").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label {
                    Text(verbatim: String(supervisor.dockerContainers.count))
                        .monospacedDigit()
                } icon: {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                }
                .font(.caption)
                Button {
                    Task { await supervisor.refreshListeningPorts() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("docker.refresh")
            }
            .padding(18)

            Divider()

            if supervisor.dockerContainers.isEmpty {
                ContentUnavailableView("docker.none", systemImage: "shippingbox", description: Text("docker.none.help"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(supervisor.dockerContainers) { container in
                            DockerContainerCard(container: container)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task { await supervisor.refreshListeningPorts() }
    }
}

private struct DockerContainerCard: View {
    let container: DockerContainerStatus
    @State private var hovering = false

    private var isHealthy: Bool { container.status.localizedCaseInsensitiveContains("healthy") }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(container.name).font(.headline)
                    Circle().fill(isHealthy ? Color.green : Color.cyan).frame(width: 6, height: 6)
                    Text(container.status)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(container.image)
                    if let project = container.project { Text("·"); Text(project) }
                    if let service = container.service { Text("/ \(service)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if container.publishedPorts.isEmpty {
                Text("docker.internal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
            } else {
                HStack(spacing: 6) {
                    ForEach(container.publishedPorts, id: \.self) { port in
                        Button {
                            NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
                        } label: {
                            Text(verbatim: ":\(port)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.blue.opacity(0.11), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(hovering ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(hovering ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.07), lineWidth: 1)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct LogsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: Supervisor
    @State private var tail = 1_000
    @State private var errorMessage: String?

    private var choices: [(String, String)] {
        supervisor.serverStatuses.map { ($0.id, $0.selector) }
            + supervisor.temporaryStatuses.map { ($0.id, "Temporary / \($0.name)") }
    }
    private var selectedID: String? {
        if let selected = model.selectedLogServerID, choices.contains(where: { $0.0 == selected }) {
            return selected
        }
        return choices.first?.0
    }
    private var lines: [String] {
        guard let selectedID else { return [] }
        return (try? supervisor.logs(server: selectedID, tail: tail)) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("settings.logs")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("logs.subtitle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if choices.isEmpty {
                    Label("logs.no.sources", systemImage: "circle.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                } else {
                    Picker("logs.server", selection: Binding(
                        get: { selectedID },
                        set: { model.selectedLogServerID = $0 }
                    )) {
                        ForEach(choices, id: \.0) { id, label in Text(label).tag(Optional(id)) }
                    }
                    .labelsHidden()
                    .frame(width: 240)

                    Stepper(value: $tail, in: 100...5_000, step: 100) {
                        HStack(spacing: 5) {
                            Text(verbatim: String(tail))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text("logs.lines").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 120)

                    Button { clear() } label: {
                        Image(systemName: "eraser")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("logs.clear")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            Divider()

            if selectedID == nil {
                LogsEmptyState {
                    model.selectedSettingsTab = .projects
                }
            } else {
                TerminalLogView(content: lines.joined(separator: "\r\n") + "\r\n")
                    .id("\(selectedID ?? "")-\(supervisor.generation)-\(tail)")
                    .background(Color(nsColor: .textBackgroundColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .errorAlert(message: $errorMessage)
    }

    private func clear() {
        guard let selectedID, let runtime = supervisor.runtime(id: selectedID) else { return }
        do { try runtime.clearLogs() } catch { errorMessage = error.localizedDescription }
    }
}

private struct LogsEmptyState: View {
    let configure: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    .frame(width: 72, height: 72)
                Image(systemName: "terminal")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 5) {
                Text("logs.none")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("logs.none.help")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button(action: configure) {
                Label("logs.configure", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [Color.clear, Color.primary.opacity(0.012)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct TerminalLogView: NSViewRepresentable {
    let content: String
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.configureNativeColors()
        view.optionAsMetaKey = false
        view.feed(text: content)
        return view
    }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

struct ResourcesSettingsView: View {
    @EnvironmentObject private var supervisor: Supervisor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("settings.resources").font(.title2.bold())
                Spacer()
                Text("resources.interval").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            List(supervisor.serverStatuses.filter { $0.pid != nil }) { status in
                if let runtime = supervisor.runtime(id: status.id) {
                    ResourceRow(runtime: runtime)
                }
            }
            .overlay {
                if supervisor.serverStatuses.allSatisfy({ $0.pid == nil }) {
                    ContentUnavailableView("resources.none", systemImage: "gauge.with.dots.needle.67percent")
                }
            }
        }
    }
}

private struct ResourceRow: View {
    @ObservedObject var runtime: ServerRuntime
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusDot(state: runtime.state)
                Text("\(runtime.projectName) / \(runtime.configuration.name)").fontWeight(.semibold)
                Spacer()
                if let metrics = runtime.metrics {
                    Label(String(format: "%.1f%%", metrics.cpuPercent), systemImage: "cpu")
                    Label(ByteCountFormatter.string(fromByteCount: Int64(metrics.footprintBytes), countStyle: .memory), systemImage: "memorychip")
                }
            }
            ResourceSparkline(samples: runtime.metricsHistory.map(\.footprintBytes))
                .frame(height: 42)
        }
        .padding(.vertical, 6)
    }
}

private struct ResourceSparkline: View {
    let samples: [UInt64]
    var body: some View {
        GeometryReader { proxy in
            let maximum = max(samples.max() ?? 1, 1)
            Path { path in
                guard samples.count > 1 else { return }
                for (index, value) in samples.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(samples.count - 1)
                    let y = proxy.size.height * (1 - CGFloat(value) / CGFloat(maximum))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
