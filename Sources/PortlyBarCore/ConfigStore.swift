import Foundation

public enum ConfigurationError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidAPIPort(Int)
    case duplicateProjectName(String)
    case duplicateServerName(project: String, server: String)
    case invalidRoot(project: String, root: String)
    case invalidServer(project: String, server: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported configuration version \(version). Expected version 1."
        case .invalidAPIPort(let port):
            return "API port \(port) is outside the valid range 1...65535."
        case .duplicateProjectName(let name):
            return "Project name '\(name)' is duplicated."
        case .duplicateServerName(let project, let server):
            return "Server name '\(server)' is duplicated in project '\(project)'."
        case .invalidRoot(let project, let root):
            return "Project '\(project)' has a non-absolute root path: \(root)."
        case .invalidServer(let project, let server, let reason):
            return "Server '\(project)/\(server)' is invalid: \(reason)."
        }
    }
}

public final class ConfigStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var value: PortlyBarConfiguration

    public init(url: URL = PortlyBarPaths.configFile) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            value = try Self.decoder.decode(PortlyBarConfiguration.self, from: data)
            try Self.validate(value)
        } else {
            value = PortlyBarConfiguration()
            try save(value)
        }
    }

    public var configuration: PortlyBarConfiguration {
        lock.withLock { value }
    }

    public func replace(with configuration: PortlyBarConfiguration) throws {
        try Self.validate(configuration)
        try save(configuration)
        lock.withLock { value = configuration }
    }

    public func mutate(_ body: (inout PortlyBarConfiguration) throws -> Void) throws {
        var next = configuration
        try body(&next)
        try replace(with: next)
    }

    public func reload() throws -> PortlyBarConfiguration {
        let data = try Data(contentsOf: url)
        let next = try Self.decoder.decode(PortlyBarConfiguration.self, from: data)
        try Self.validate(next)
        lock.withLock { value = next }
        return next
    }

    public static func validate(_ configuration: PortlyBarConfiguration) throws {
        guard configuration.version == 1 else {
            throw ConfigurationError.unsupportedVersion(configuration.version)
        }
        guard (1...65_535).contains(configuration.apiPort) else {
            throw ConfigurationError.invalidAPIPort(configuration.apiPort)
        }
        var projectNames = Set<String>()
        for project in configuration.projects {
            let normalizedProject = project.name.lowercased()
            guard projectNames.insert(normalizedProject).inserted else {
                throw ConfigurationError.duplicateProjectName(project.name)
            }
            guard project.root.hasPrefix("/") else {
                throw ConfigurationError.invalidRoot(project: project.name, root: project.root)
            }
            var serverNames = Set<String>()
            for server in project.servers {
                guard serverNames.insert(server.name.lowercased()).inserted else {
                    throw ConfigurationError.duplicateServerName(project: project.name, server: server.name)
                }
                guard !server.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigurationError.invalidServer(
                        project: project.name,
                        server: server.name,
                        reason: "command is empty"
                    )
                }
                if let port = server.port, !(1...65_535).contains(port) {
                    throw ConfigurationError.invalidServer(
                        project: project.name,
                        server: server.name,
                        reason: "port \(port) is outside 1...65535"
                    )
                }
            }
        }
    }

    private func save(_ configuration: PortlyBarConfiguration) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(configuration)
        try data.write(to: url, options: [.atomic])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
