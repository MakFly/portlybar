import Foundation

public struct ServerConfiguration: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var port: Int?
    public var directory: String?
    public var environment: [String: String]
    public var healthURL: String?
    public var expectedHealthStatus: Int?
    public var autoRestart: Bool

    public init(
        id: String = "srv_\(UUID().uuidString.lowercased())",
        name: String,
        command: String,
        port: Int? = nil,
        directory: String? = nil,
        environment: [String: String] = [:],
        healthURL: String? = nil,
        expectedHealthStatus: Int? = nil,
        autoRestart: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.port = port
        self.directory = directory
        self.environment = environment
        self.healthURL = healthURL
        self.expectedHealthStatus = expectedHealthStatus
        self.autoRestart = autoRestart
    }
}

public enum MemoryLimitMode: String, Codable, CaseIterable, Sendable {
    case inherit
    case disabled
    case custom
}

public struct ProjectConfiguration: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var root: String
    public var icon: String
    public var color: String
    public var servers: [ServerConfiguration]
    public var memoryLimitMode: MemoryLimitMode
    public var memoryLimitBytes: UInt64?

    public init(
        id: String = "prj_\(UUID().uuidString.lowercased())",
        name: String,
        root: String,
        icon: String = "shippingbox",
        color: String = "#0A84FF",
        servers: [ServerConfiguration] = [],
        memoryLimitMode: MemoryLimitMode = .inherit,
        memoryLimitBytes: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.root = root
        self.icon = icon
        self.color = color
        self.servers = servers
        self.memoryLimitMode = memoryLimitMode
        self.memoryLimitBytes = memoryLimitBytes
    }

    public func effectiveMemoryLimit(global: UInt64?) -> UInt64? {
        switch memoryLimitMode {
        case .inherit: return global
        case .disabled: return nil
        case .custom: return memoryLimitBytes
        }
    }
}

public struct PortlyBarConfiguration: Codable, Hashable, Sendable {
    public var version: Int
    public var apiPort: Int
    public var healthIntervalSeconds: Int
    public var maxRestartAttempts: Int
    public var logBufferLines: Int
    public var logFileMaxMB: Int
    public var globalMemoryLimitBytes: UInt64?
    public var projects: [ProjectConfiguration]

    public init(
        version: Int = 1,
        apiPort: Int = PortlyBarPaths.defaultAPIPort,
        healthIntervalSeconds: Int = 10,
        maxRestartAttempts: Int = 5,
        logBufferLines: Int = 5_000,
        logFileMaxMB: Int = 10,
        globalMemoryLimitBytes: UInt64? = nil,
        projects: [ProjectConfiguration] = []
    ) {
        self.version = version
        self.apiPort = apiPort
        self.healthIntervalSeconds = healthIntervalSeconds
        self.maxRestartAttempts = maxRestartAttempts
        self.logBufferLines = logBufferLines
        self.logFileMaxMB = logFileMaxMB
        self.globalMemoryLimitBytes = globalMemoryLimitBytes
        self.projects = projects
    }

    public func resolveProject(_ query: String) -> ProjectConfiguration? {
        projects.first { $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame }
    }

    public func resolveServer(_ query: String) -> (ProjectConfiguration, ServerConfiguration)? {
        let parts = query.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, let project = resolveProject(parts[0]) {
            return project.servers.first {
                $0.id == parts[1] || $0.name.caseInsensitiveCompare(parts[1]) == .orderedSame
            }.map { (project, $0) }
        }
        let matches = projects.flatMap { project in
            project.servers.compactMap { server in
                server.id == query || server.name.caseInsensitiveCompare(query) == .orderedSame
                    ? (project, server) : nil
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

public enum ServerState: String, Codable, Hashable, Sendable {
    case stopped
    case starting
    case running
    case unhealthy
    case stopping
    case failed
}

public struct ProcessMetrics: Codable, Hashable, Sendable {
    public var cpuPercent: Double
    public var residentBytes: UInt64
    public var footprintBytes: UInt64
    public var sampledAt: Date

    public init(cpuPercent: Double, residentBytes: UInt64, footprintBytes: UInt64, sampledAt: Date = .now) {
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.sampledAt = sampledAt
    }
}

public struct ServerStatus: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var projectID: String
    public var projectName: String
    public var name: String
    public var state: ServerState
    public var port: Int?
    public var pid: Int32?
    public var startedAt: Date?
    public var exitCode: Int32?
    public var restartAttempts: Int
    public var lastError: String?
    public var metrics: ProcessMetrics?

    public var selector: String { "\(projectName)/\(name)" }

    public init(
        id: String,
        projectID: String,
        projectName: String,
        name: String,
        state: ServerState,
        port: Int?,
        pid: Int32?,
        startedAt: Date?,
        exitCode: Int32?,
        restartAttempts: Int,
        lastError: String?,
        metrics: ProcessMetrics?
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.name = name
        self.state = state
        self.port = port
        self.pid = pid
        self.startedAt = startedAt
        self.exitCode = exitCode
        self.restartAttempts = restartAttempts
        self.lastError = lastError
        self.metrics = metrics
    }
}

public enum TemporaryJobState: String, Codable, Hashable, Sendable {
    case running
    case stopped
    case succeeded
    case failed
    case timedOut
}

public struct TemporaryJobStatus: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var directory: String
    public var state: TemporaryJobState
    public var pid: Int32?
    public var startedAt: Date
    public var finishedAt: Date?
    public var timeoutSeconds: Int
    public var exitCode: Int32?
    public var error: String?

    public init(
        id: String,
        name: String,
        command: String,
        directory: String,
        state: TemporaryJobState,
        pid: Int32?,
        startedAt: Date,
        finishedAt: Date?,
        timeoutSeconds: Int,
        exitCode: Int32?,
        error: String?
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.directory = directory
        self.state = state
        self.pid = pid
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.timeoutSeconds = timeoutSeconds
        self.exitCode = exitCode
        self.error = error
    }
}

public enum PortOwnership: String, Codable, Hashable, Sendable {
    case managed
    case external
    case protected
}

public struct ListeningPort: Codable, Identifiable, Hashable, Sendable {
    public var port: Int
    public var pid: Int32
    public var command: String
    public var user: String
    public var workingDirectory: String?
    public var ownership: PortOwnership
    public var managedServerID: String?

    public var id: String { "\(pid):\(port)" }

    public init(
        port: Int,
        pid: Int32,
        command: String,
        user: String,
        workingDirectory: String?,
        ownership: PortOwnership,
        managedServerID: String?
    ) {
        self.port = port
        self.pid = pid
        self.command = command
        self.user = user
        self.workingDirectory = workingDirectory
        self.ownership = ownership
        self.managedServerID = managedServerID
    }
}

public struct SupervisorStatus: Codable, Hashable, Sendable {
    public var version: String
    public var servers: [ServerStatus]
    public var temporaryJobs: [TemporaryJobStatus]

    public init(version: String, servers: [ServerStatus], temporaryJobs: [TemporaryJobStatus]) {
        self.version = version
        self.servers = servers
        self.temporaryJobs = temporaryJobs
    }
}

public enum MemorySize {
    public static func parse(_ raw: String) -> UInt64? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let units: [(String, Double)] = [
            ("gib", 1_073_741_824), ("gb", 1_000_000_000),
            ("mib", 1_048_576), ("mb", 1_000_000),
            ("kib", 1_024), ("kb", 1_000), ("b", 1),
        ]
        guard let unit = units.first(where: { value.hasSuffix($0.0) }) else {
            return UInt64(value)
        }
        guard let amount = Double(value.dropLast(unit.0.count)), amount >= 0 else { return nil }
        return UInt64(amount * unit.1)
    }
}
