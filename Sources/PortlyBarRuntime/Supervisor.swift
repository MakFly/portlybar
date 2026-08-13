import Combine
import Foundation
import PortlyBarCore

public enum SupervisorError: LocalizedError {
    case projectNotFound(String)
    case serverNotFound(String)
    case duplicateProject(String)
    case duplicateServer(project: String, server: String)
    case runningServer(String)
    case temporaryJobNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let value): return "Project not found: \(value)."
        case .serverNotFound(let value): return "Server not found or ambiguous: \(value)."
        case .duplicateProject(let value): return "Project already exists: \(value)."
        case .duplicateServer(let project, let server): return "Server already exists: \(project)/\(server)."
        case .runningServer(let value): return "Stop \(value) before changing or removing it."
        case .temporaryJobNotFound(let value): return "Temporary job not found: \(value)."
        }
    }
}

@MainActor
public final class Supervisor: ObservableObject {
    public static let version = portlyBarVersion

    @Published public private(set) var configuration: PortlyBarConfiguration
    @Published public private(set) var serverStatuses: [ServerStatus] = []
    @Published public private(set) var temporaryStatuses: [TemporaryJobStatus] = []
    @Published public private(set) var listeningPorts: [ListeningPort] = []
    @Published public private(set) var dockerContainers: [DockerContainerStatus] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var generation = 0

    public let store: ConfigStore
    private var runtimes: [String: ServerRuntime] = [:]
    private var temporaryIDs: [String] = []
    private var metricsTask: Task<Void, Never>?
    private var memoryBreaches: [String: Int] = [:]

    public init(store: ConfigStore? = nil) throws {
        let resolvedStore = try store ?? ConfigStore()
        self.store = resolvedStore
        self.configuration = resolvedStore.configuration
        try rebuildRuntimes()
        startMetricsLoop()
        Task { @MainActor [weak self] in await self?.refreshListeningPorts() }
    }

    deinit { metricsTask?.cancel() }

    public var projects: [ProjectConfiguration] { configuration.projects }
    public var runningCount: Int { serverStatuses.filter { $0.state == .running || $0.state == .starting }.count }
    public var hasProblems: Bool { serverStatuses.contains { $0.state == .failed || $0.state == .unhealthy } }
    public var hasActiveProcesses: Bool { serverStatuses.contains { $0.pid != nil } || temporaryStatuses.contains { $0.state == .running } }

    public func runtime(id: String) -> ServerRuntime? { runtimes[id] }

    public func runtime(selector: String) throws -> ServerRuntime {
        guard let (_, server) = configuration.resolveServer(selector), let runtime = runtimes[server.id] else {
            throw SupervisorError.serverNotFound(selector)
        }
        return runtime
    }

    public func status() -> SupervisorStatus {
        SupervisorStatus(version: Self.version, servers: serverStatuses, temporaryJobs: temporaryStatuses)
    }

    public func start(server selector: String) throws { try runtime(selector: selector).start() }
    public func stop(server selector: String, force: Bool = false) throws { try runtime(selector: selector).stop(force: force) }
    public func restart(server selector: String) throws { try runtime(selector: selector).restart() }

    public func start(project query: String) throws {
        guard let project = configuration.resolveProject(query) else { throw SupervisorError.projectNotFound(query) }
        for server in project.servers { runtimes[server.id]?.start() }
    }

    public func stop(project query: String, force: Bool = false) throws {
        guard let project = configuration.resolveProject(query) else { throw SupervisorError.projectNotFound(query) }
        for server in project.servers { runtimes[server.id]?.stop(force: force) }
    }

    public func restart(project query: String) throws {
        guard let project = configuration.resolveProject(query) else { throw SupervisorError.projectNotFound(query) }
        for server in project.servers { runtimes[server.id]?.restart() }
    }

    public func stopAll(force: Bool = false) {
        for runtime in runtimes.values where runtime.status.pid != nil { runtime.stop(force: force) }
    }

    public func terminateEverythingSynchronously(gracePeriod: TimeInterval = 5) {
        stopAll()
        let deadline = Date().addingTimeInterval(gracePeriod)
        while hasActiveProcesses, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if hasActiveProcesses { stopAll(force: true) }
    }

    public func logs(server selector: String, tail: Int) throws -> [String] {
        if let temporary = runtimes[selector], temporary.isTemporary { return temporary.logs(tail: tail) }
        return try runtime(selector: selector).logs(tail: tail)
    }

    public func ports() -> [ListeningPort] {
        listeningPorts
    }

    public func stopExternalPort(_ request: PortRequest) throws {
        guard let expectedPID = request.expectedPID else {
            throw NSError(
                domain: "PortlyBarPorts",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "expectedPID is required to stop a port safely."]
            )
        }
        try PortInspector.stop(port: request.port, expectedPID: expectedPID, force: request.force == true)
    }

    public func takeOver(server selector: String) async throws {
        let runtime = try runtime(selector: selector)
        guard let port = runtime.configuration.port else {
            throw NSError(domain: "PortlyBarPorts", code: 2, userInfo: [NSLocalizedDescriptionKey: "Server \(selector) has no configured port."])
        }
        if let occupant = PortInspector.occupant(of: port) {
            try PortInspector.stop(port: port, expectedPID: occupant.pid)
            for _ in 0..<20 {
                if PortInspector.occupant(of: port) == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard PortInspector.occupant(of: port) == nil else {
                throw NSError(domain: "PortlyBarPorts", code: 3, userInfo: [NSLocalizedDescriptionKey: "Port \(port) did not become free after SIGTERM."])
            }
        }
        runtime.start()
    }

    public func addProject(_ project: ProjectConfiguration) throws {
        guard configuration.resolveProject(project.name) == nil else { throw SupervisorError.duplicateProject(project.name) }
        try store.mutate { $0.projects.append(project) }
        configuration = store.configuration
        try rebuildRuntimes()
    }

    public func updateProject(_ project: ProjectConfiguration) throws {
        guard let index = configuration.projects.firstIndex(where: { $0.id == project.id }) else {
            throw SupervisorError.projectNotFound(project.id)
        }
        let active = configuration.projects[index].servers.compactMap { runtimes[$0.id] }.contains { $0.status.pid != nil }
        guard !active else { throw SupervisorError.runningServer(project.name) }
        try store.mutate { $0.projects[index] = project }
        configuration = store.configuration
        try rebuildRuntimes()
    }

    public func removeProject(_ query: String) throws {
        guard let project = configuration.resolveProject(query) else { throw SupervisorError.projectNotFound(query) }
        guard !project.servers.compactMap({ runtimes[$0.id] }).contains(where: { $0.status.pid != nil }) else {
            throw SupervisorError.runningServer(project.name)
        }
        try store.mutate { $0.projects.removeAll { $0.id == project.id } }
        configuration = store.configuration
        try rebuildRuntimes()
    }

    public func addServer(project query: String, server: ServerConfiguration, start: Bool = false) throws {
        guard let projectIndex = configuration.projects.firstIndex(where: {
            $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame
        }) else { throw SupervisorError.projectNotFound(query) }
        let project = configuration.projects[projectIndex]
        guard !project.servers.contains(where: { $0.name.caseInsensitiveCompare(server.name) == .orderedSame }) else {
            throw SupervisorError.duplicateServer(project: project.name, server: server.name)
        }
        try store.mutate { $0.projects[projectIndex].servers.append(server) }
        configuration = store.configuration
        try rebuildRuntimes()
        if start { runtimes[server.id]?.start() }
    }

    public func updateServer(project query: String, server: ServerConfiguration) throws {
        guard let projectIndex = configuration.projects.firstIndex(where: {
            $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame
        }) else { throw SupervisorError.projectNotFound(query) }
        guard let serverIndex = configuration.projects[projectIndex].servers.firstIndex(where: { $0.id == server.id }) else {
            throw SupervisorError.serverNotFound(server.id)
        }
        guard runtimes[server.id]?.status.pid == nil else { throw SupervisorError.runningServer(server.name) }
        try store.mutate { $0.projects[projectIndex].servers[serverIndex] = server }
        configuration = store.configuration
        try rebuildRuntimes()
    }

    public func removeServer(_ selector: String) throws {
        guard let (project, server) = configuration.resolveServer(selector) else { throw SupervisorError.serverNotFound(selector) }
        guard runtimes[server.id]?.status.pid == nil else { throw SupervisorError.runningServer(selector) }
        guard let projectIndex = configuration.projects.firstIndex(where: { $0.id == project.id }) else { return }
        try store.mutate { $0.projects[projectIndex].servers.removeAll { $0.id == server.id } }
        configuration = store.configuration
        try rebuildRuntimes()
    }

    @discardableResult
    public func runTemporary(_ request: TemporaryRunRequest) throws -> TemporaryJobStatus {
        guard request.timeoutSeconds > 0 else {
            throw NSError(domain: "PortlyBarTemporary", code: 1, userInfo: [NSLocalizedDescriptionKey: "timeoutSeconds must be greater than zero."])
        }
        let id = "tmp_\(UUID().uuidString.lowercased())"
        let project = ProjectConfiguration(id: "temporary", name: "Temporary", root: request.directory)
        let server = ServerConfiguration(
            id: id,
            name: request.name,
            command: request.command,
            port: request.port,
            environment: request.environment,
            autoRestart: false
        )
        let runtime = try makeRuntime(project: project, server: server, temporary: true, timeoutSeconds: request.timeoutSeconds)
        runtimes[id] = runtime
        temporaryIDs.append(id)
        runtime.start()
        refreshPublishedState()
        guard let status = runtime.temporaryStatus else { throw SupervisorError.temporaryJobNotFound(id) }
        return status
    }

    public func startTemporaryHTTPServer(_ request: TemporaryHTTPServerRequest) async throws -> TemporaryHTTPServerStatus {
        guard FileManager.default.fileExists(atPath: request.directory) else {
            throw NSError(
                domain: "PortlyBarHTTPServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Working directory does not exist: \(request.directory)"]
            )
        }
        guard request.startupTimeoutSeconds > 0 else {
            throw NSError(
                domain: "PortlyBarHTTPServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "startupTimeoutSeconds must be greater than zero."]
            )
        }
        guard request.timeoutSeconds > 0 else {
            throw NSError(
                domain: "PortlyBarHTTPServer",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "timeoutSeconds must be greater than zero."]
            )
        }

        var collisionMessages: [String] = []
        for _ in 0..<3 {
            let port = try PortAllocator.availablePort(minimum: request.minimumPort, maximum: request.maximumPort)
            var environment = request.environment
            environment["HOST"] = "127.0.0.1"
            let initial = try runTemporary(TemporaryRunRequest(
                name: request.name,
                command: request.command,
                directory: request.directory,
                port: port,
                environment: environment,
                timeoutSeconds: request.timeoutSeconds
            ))
            let deadline = Date().addingTimeInterval(TimeInterval(request.startupTimeoutSeconds))

            while Date() < deadline {
                let status = try temporaryStatus(id: initial.id)
                if status.state != .running {
                    let output = try logs(server: initial.id, tail: 100).joined(separator: "\n")
                    if isAddressCollision(output) {
                        collisionMessages.append("Port \(port): \(output)")
                        break
                    }
                    throw NSError(
                        domain: "PortlyBarHTTPServer",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP server exited before becoming ready on port \(port).\n\(output)"]
                    )
                }
                if await HealthChecker.checkHTTP(
                    port: port,
                    path: request.healthPath,
                    expectedStatus: request.expectedStatus
                ) {
                    let path = request.healthPath.hasPrefix("/") ? request.healthPath : "/\(request.healthPath)"
                    return TemporaryHTTPServerStatus(job: status, port: port, url: "http://127.0.0.1:\(port)\(path)")
                }
                try await Task.sleep(for: .milliseconds(200))
            }

            let output = try logs(server: initial.id, tail: 100).joined(separator: "\n")
            _ = try await stopTemporary(id: initial.id)
            if !isAddressCollision(output) {
                throw NSError(
                    domain: "PortlyBarHTTPServer",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP server did not answer on http://127.0.0.1:\(port)\(request.healthPath) within \(request.startupTimeoutSeconds) seconds.\n\(output)"]
                )
            }
            collisionMessages.append("Port \(port): \(output)")
        }

        throw NSError(
            domain: "PortlyBarHTTPServer",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Unable to start the HTTP server after three port collisions.\n\(collisionMessages.joined(separator: "\n"))"]
        )
    }

    public func stopTemporary(id: String) async throws -> TemporaryJobStatus {
        guard let runtime = runtimes[id], runtime.isTemporary else {
            throw SupervisorError.temporaryJobNotFound(id)
        }
        runtime.stop()
        for _ in 0..<50 {
            if runtime.status.pid == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if runtime.status.pid != nil {
            runtime.stop(force: true)
            for _ in 0..<10 {
                if runtime.status.pid == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard runtime.status.pid == nil, let status = runtime.temporaryStatus else {
            throw NSError(
                domain: "PortlyBarTemporary",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Temporary job \(id) did not stop after SIGTERM and SIGKILL."]
            )
        }
        return status
    }

    public func temporaryStatus(id: String) throws -> TemporaryJobStatus {
        guard let status = runtimes[id]?.temporaryStatus else { throw SupervisorError.temporaryJobNotFound(id) }
        return status
    }

    private func isAddressCollision(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("eaddrinuse") || normalized.contains("address already in use")
    }

    public func setMemoryLimit(_ request: MemoryLimitRequest) throws {
        if let query = request.project {
            guard let index = configuration.projects.firstIndex(where: {
                $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame
            }) else { throw SupervisorError.projectNotFound(query) }
            try store.mutate {
                $0.projects[index].memoryLimitMode = request.mode
                $0.projects[index].memoryLimitBytes = request.mode == .custom ? request.bytes : nil
            }
        } else {
            try store.mutate { $0.globalMemoryLimitBytes = request.mode == .disabled ? nil : request.bytes }
        }
        configuration = store.configuration
        memoryBreaches.removeAll()
        refreshPublishedState()
    }

    public func updateRuntimeSettings(healthInterval: Int, restartAttempts: Int, logLines: Int, logFileMB: Int) throws {
        try store.mutate {
            $0.healthIntervalSeconds = healthInterval
            $0.maxRestartAttempts = restartAttempts
            $0.logBufferLines = logLines
            $0.logFileMaxMB = logFileMB
        }
        configuration = store.configuration
        for runtime in runtimes.values { runtime.update(configuration: runtime.configuration) }
        refreshPublishedState()
    }

    public func reloadConfiguration() throws {
        configuration = try store.reload()
        try rebuildRuntimes()
    }

    public func record(error: Error) {
        lastError = error.localizedDescription
    }

    public func activeSelectors() -> [String] {
        serverStatuses.filter { $0.pid != nil }.map(\.selector)
    }

    public func restore(selectors: [String]) {
        for selector in selectors { try? start(server: selector) }
    }

    private func rebuildRuntimes() throws {
        let configuredIDs = Set(configuration.projects.flatMap { $0.servers.map(\.id) })
        for (id, runtime) in runtimes where !configuredIDs.contains(id) && !runtime.isTemporary {
            guard runtime.status.pid == nil else { continue }
            runtimes.removeValue(forKey: id)
        }
        for project in configuration.projects {
            for server in project.servers {
                if let existing = runtimes[server.id] { existing.update(configuration: server) }
                else { runtimes[server.id] = try makeRuntime(project: project, server: server) }
            }
        }
        refreshPublishedState()
    }

    private func makeRuntime(
        project: ProjectConfiguration,
        server: ServerConfiguration,
        temporary: Bool = false,
        timeoutSeconds: Int? = nil
    ) throws -> ServerRuntime {
        let runtime = try ServerRuntime(
            project: project,
            configuration: server,
            isTemporary: temporary,
            timeoutSeconds: timeoutSeconds,
            settings: { [weak self] in self?.configuration ?? PortlyBarConfiguration() },
            logsDirectory: store.url.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        )
        runtime.onChange = { [weak self] in self?.refreshPublishedState() }
        return runtime
    }

    private func refreshPublishedState() {
        serverStatuses = configuration.projects.flatMap { project in
            project.servers.compactMap { runtimes[$0.id]?.status }
        }
        temporaryStatuses = temporaryIDs.compactMap { runtimes[$0]?.temporaryStatus }
        generation += 1
    }

    private func startMetricsLoop() {
        metricsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                for runtime in self.runtimes.values where runtime.status.pid != nil { runtime.sampleMetrics() }
                self.applyMemoryGuards()
                self.pruneTemporaryJobs()
                await self.refreshListeningPorts()
            }
        }
    }

    public func refreshListeningPorts() async {
        let managed = Dictionary(uniqueKeysWithValues: runtimes.values.compactMap { runtime in
            runtime.status.pid.map { ($0, runtime.id) }
        })
        let controlPort = configuration.apiPort
        let detected = await Task.detached(priority: .utility) {
            let ports = PortInspector.listeners(managed: managed).filter { $0.port != controlPort }
            return (ports, DockerPortInspector.runningContainers())
        }.value
        listeningPorts = detected.0
        dockerContainers = detected.1
    }

    private func applyMemoryGuards() {
        for project in configuration.projects {
            guard let limit = project.effectiveMemoryLimit(global: configuration.globalMemoryLimitBytes) else {
                memoryBreaches[project.id] = 0
                continue
            }
            let active = project.servers.compactMap { runtimes[$0.id] }.filter { $0.status.pid != nil }
            let total = active.compactMap { $0.metrics?.footprintBytes }.reduce(0, +)
            guard !active.isEmpty, total > limit else { memoryBreaches[project.id] = 0; continue }
            let count = (memoryBreaches[project.id] ?? 0) + 1
            memoryBreaches[project.id] = count
            if count >= 3 {
                for runtime in active { runtime.restart() }
                memoryBreaches[project.id] = 0
            }
        }
    }

    private func pruneTemporaryJobs() {
        let cutoff = Date().addingTimeInterval(-3_600)
        let expired = temporaryIDs.filter { id in
            guard let runtime = runtimes[id], let finishedAt = runtime.finishedAt else { return false }
            return finishedAt < cutoff
        }
        for id in expired { runtimes.removeValue(forKey: id) }
        temporaryIDs.removeAll { expired.contains($0) }
        if !expired.isEmpty { refreshPublishedState() }
    }
}
