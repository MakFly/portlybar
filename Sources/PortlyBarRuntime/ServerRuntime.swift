import Combine
import Foundation
import PortlyBarCore

@MainActor
public final class ServerRuntime: ObservableObject, Identifiable, PTYProcessDelegate {
    public let id: String
    public let projectID: String
    public let projectName: String
    public let projectRoot: String
    public private(set) var configuration: ServerConfiguration
    public let isTemporary: Bool

    @Published public private(set) var state: ServerState = .stopped
    @Published public private(set) var pid: Int32?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var finishedAt: Date?
    @Published public private(set) var exitCode: Int32?
    @Published public private(set) var restartAttempts = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var metrics: ProcessMetrics?
    @Published public private(set) var metricsHistory: [ProcessMetrics] = []

    public var timeoutSeconds: Int?
    public var temporaryState: TemporaryJobState?
    public var onChange: (() -> Void)?

    private let settings: () -> PortlyBarConfiguration
    private let logStore: LogStore
    private var process: PTYProcess?
    private var healthTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var stopRequested = false
    private var healthFailures = 0

    public init(
        project: ProjectConfiguration,
        configuration: ServerConfiguration,
        isTemporary: Bool = false,
        timeoutSeconds: Int? = nil,
        settings: @escaping () -> PortlyBarConfiguration,
        logsDirectory: URL = PortlyBarPaths.logsDirectory
    ) throws {
        self.id = configuration.id
        self.projectID = project.id
        self.projectName = project.name
        self.projectRoot = project.root
        self.configuration = configuration
        self.isTemporary = isTemporary
        self.timeoutSeconds = timeoutSeconds
        self.settings = settings
        let current = settings()
        self.logStore = try LogStore(
            serverID: configuration.id,
            maxLines: current.logBufferLines,
            maxFileMB: current.logFileMaxMB,
            directory: logsDirectory
        )
    }

    public var status: ServerStatus {
        ServerStatus(
            id: id,
            projectID: projectID,
            projectName: projectName,
            name: configuration.name,
            state: state,
            port: configuration.port,
            pid: pid,
            startedAt: startedAt,
            exitCode: exitCode,
            restartAttempts: restartAttempts,
            lastError: lastError,
            metrics: metrics
        )
    }

    public var temporaryStatus: TemporaryJobStatus? {
        guard isTemporary, let timeoutSeconds, let startedAt else { return nil }
        let mapped: TemporaryJobState
        if let temporaryState { mapped = temporaryState }
        else if state == .running || state == .starting { mapped = .running }
        else { mapped = exitCode == 0 ? .succeeded : .failed }
        return TemporaryJobStatus(
            id: id,
            name: configuration.name,
            command: configuration.command,
            directory: workingDirectory,
            state: mapped,
            pid: pid,
            startedAt: startedAt,
            finishedAt: finishedAt,
            timeoutSeconds: timeoutSeconds,
            exitCode: exitCode,
            error: lastError
        )
    }

    public var workingDirectory: String {
        guard let directory = configuration.directory, !directory.isEmpty else { return projectRoot }
        if directory.hasPrefix("/") { return directory }
        return URL(fileURLWithPath: projectRoot).appendingPathComponent(directory).standardized.path
    }

    public func update(configuration: ServerConfiguration) {
        self.configuration = configuration
        let current = settings()
        logStore.updateLimits(maxLines: current.logBufferLines, maxFileMB: current.logFileMaxMB)
        onChange?()
    }

    public func start(resetAttempts: Bool = true) {
        guard state == .stopped || state == .failed || state == .unhealthy else { return }
        if let port = configuration.port,
           let occupant = PortInspector.occupant(of: port),
           occupant.pid != pid {
            state = .failed
            lastError = "Port \(port) is already owned by \(occupant.command) (PID \(occupant.pid))."
            onChange?()
            return
        }
        if resetAttempts { restartAttempts = 0 }
        stopRequested = false
        healthFailures = 0
        lastError = nil
        exitCode = nil
        finishedAt = nil
        temporaryState = isTemporary ? .running : nil
        state = .starting
        logStore.append(text: "[portlybar] starting \(configuration.name)\n")

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in configuration.environment { environment[key] = value }
        environment["TERM"] = "xterm-256color"
        environment["PORTLYBAR"] = "1"
        environment["PORTLYBAR_SERVER"] = configuration.name
        if let port = configuration.port { environment["PORT"] = String(port) }

        let runner = PTYProcess(delegate: self)
        process = runner
        do {
            try runner.start(command: configuration.command, directory: workingDirectory, environment: environment)
            pid = runner.pid
            startedAt = .now
            if configuration.port == nil {
                state = .running
            } else {
                startHealthLoop()
            }
            startTimeoutIfNeeded()
        } catch {
            process = nil
            pid = nil
            state = .failed
            lastError = error.localizedDescription
            if isTemporary { temporaryState = .failed; finishedAt = .now }
        }
        onChange?()
    }

    public func stop(force: Bool = false, timedOut: Bool = false) {
        guard process != nil else {
            state = .stopped
            return
        }
        stopRequested = !timedOut
        if timedOut {
            temporaryState = .timedOut
            lastError = "Job exceeded its \(timeoutSeconds ?? 0)-second timeout."
        }
        state = .stopping
        healthTask?.cancel()
        timeoutTask?.cancel()
        process?.terminate(force: force)
        onChange?()
    }

    public func restart() {
        stopRequested = true
        stop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            if self.process == nil { self.start() }
        }
    }

    public func send(_ text: String) { process?.send(text) }

    public func logs(tail: Int = 200) -> [String] { logStore.tail(tail) }

    public func clearLogs() throws { try logStore.clear() }

    public func sampleMetrics() {
        guard let pid, let sample = ProcessSampler.sampleTree(rootPID: pid) else {
            metrics = nil
            return
        }
        metrics = sample
        metricsHistory.append(sample)
        if metricsHistory.count > 150 { metricsHistory.removeFirst(metricsHistory.count - 150) }
        onChange?()
    }

    nonisolated public func ptyProcess(_ process: PTYProcess, received bytes: ArraySlice<UInt8>) {
        let copied = Array(bytes)
        Task { @MainActor [weak self] in self?.logStore.append(bytes: copied[...]); self?.onChange?() }
    }

    nonisolated public func ptyProcess(_ process: PTYProcess, terminatedWith exitCode: Int32?) {
        Task { @MainActor [weak self] in self?.handleTermination(exitCode: exitCode) }
    }

    private func handleTermination(exitCode: Int32?) {
        let explicitlyStopped = stopRequested
        self.exitCode = exitCode
        self.process = nil
        self.pid = nil
        self.healthTask?.cancel()
        self.timeoutTask?.cancel()
        self.finishedAt = .now
        self.metrics = nil

        if isTemporary {
            if temporaryState == .timedOut {
                state = .failed
            } else if explicitlyStopped {
                temporaryState = .stopped
                state = .stopped
            } else {
                temporaryState = exitCode == 0 ? .succeeded : .failed
                state = exitCode == 0 ? .stopped : .failed
            }
        } else if explicitlyStopped {
            state = .stopped
        } else if exitCode == 0 {
            state = .stopped
        } else {
            state = .failed
            lastError = "Process exited with code \(exitCode.map(String.init) ?? "unknown")."
            scheduleRestartIfAllowed()
        }
        onChange?()
    }

    private func startHealthLoop() {
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            guard let self, let port = self.configuration.port else { return }
            while !Task.isCancelled, self.process != nil {
                let healthy = await HealthChecker.check(
                    port: port,
                    healthURL: self.configuration.healthURL,
                    expectedStatus: self.configuration.expectedHealthStatus
                )
                guard !Task.isCancelled, self.process != nil else { return }
                if healthy {
                    self.healthFailures = 0
                    self.state = .running
                } else {
                    self.healthFailures += 1
                    if self.state == .running { self.state = .unhealthy }
                    if self.healthFailures >= 3, self.configuration.autoRestart {
                        self.lastError = "Health check failed three consecutive times."
                        self.process?.terminate()
                        return
                    }
                }
                self.onChange?()
                try? await Task.sleep(for: .seconds(max(1, self.settings().healthIntervalSeconds)))
            }
        }
    }

    private func scheduleRestartIfAllowed() {
        guard configuration.autoRestart, restartAttempts < settings().maxRestartAttempts else { return }
        restartAttempts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.state == .failed, !self.stopRequested else { return }
            self.start(resetAttempts: false)
        }
    }

    private func startTimeoutIfNeeded() {
        guard isTemporary, let timeoutSeconds else { return }
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.process != nil else { return }
            self.stop(timedOut: true)
        }
    }
}
