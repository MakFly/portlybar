import Foundation

public struct DockerPublishedContainer: Hashable, Sendable {
    public let id: String
    public let name: String
    public let hostPort: Int
}

public enum DockerContainerState: String, Codable, Sendable {
    case running
    case paused
    case restarting
    case created
    case exited
    case dead
    case unknown

    init(rawDockerState: String) {
        self = DockerContainerState(rawValue: rawDockerState.lowercased()) ?? .unknown
    }

    public var isRunning: Bool { self == .running || self == .restarting }
}

public struct DockerContainerStatus: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let state: DockerContainerState
    public let status: String
    public let publishedPorts: [Int]
    public let project: String?
    public let service: String?

    public init(
        id: String,
        name: String,
        image: String,
        state: DockerContainerState,
        status: String,
        publishedPorts: [Int],
        project: String?,
        service: String?
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.publishedPorts = publishedPorts
        self.project = project
        self.service = service
    }
}

public enum DockerPortInspector {
    /// Every container known to Docker, running or not, running ones first.
    public static func containers() -> [DockerContainerStatus] {
        guard let docker = dockerExecutable() else { return [] }
        let format = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}"
        let result = run(docker, ["ps", "--all", "--format", format])
        guard result.status == 0 else { return [] }

        return result.output.split(separator: "\n").compactMap { parse(String($0)) }.sorted {
            if $0.state.isRunning != $1.state.isRunning { return $0.state.isRunning }
            return ($0.project ?? $0.name, $0.name) < ($1.project ?? $1.name, $1.name)
        }
    }

    static func parse(_ line: String) -> DockerContainerStatus? {
        let fields = line.components(separatedBy: "\t")
        guard fields.count >= 8 else { return nil }
        return DockerContainerStatus(
            id: fields[0],
            name: fields[1],
            image: fields[2],
            state: DockerContainerState(rawDockerState: fields[3]),
            status: fields[4],
            publishedPorts: publishedHostPorts(fields[5]),
            project: fields[6].isEmpty ? nil : fields[6],
            service: fields[7].isEmpty ? nil : fields[7]
        )
    }

    public static func container(publishing port: Int) -> DockerPublishedContainer? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/local/bin/docker")
                || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/docker") else { return nil }
        guard let docker = dockerExecutable() else { return nil }
        let result = run(docker, ["ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Ports}}"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3, publishes(fields[2], port: port) else { continue }
            return DockerPublishedContainer(id: fields[0], name: fields[1], hostPort: port)
        }
        return nil
    }

    public static func stop(_ container: DockerPublishedContainer) throws {
        try stop(id: container.id, label: container.name)
    }

    public static func stop(id: String, label: String? = nil) throws {
        try perform(["stop", "--time", "5", id], verb: "stop", label: label ?? id)
    }

    public static func start(id: String, label: String? = nil) throws {
        try perform(["start", id], verb: "start", label: label ?? id)
    }

    private static func perform(_ arguments: [String], verb: String, label: String) throws {
        guard let docker = dockerExecutable() else {
            throw NSError(domain: "PortlyBarDocker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Docker CLI is unavailable."])
        }
        let result = run(docker, arguments)
        guard result.status == 0 else {
            throw NSError(
                domain: "PortlyBarDocker",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to \(verb) Docker container \(label): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"]
            )
        }
    }

    static func publishes(_ ports: String, port: Int) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: String(port))
        let pattern = "(?:^|[, ])(?:[^, ]*:)?\(escaped)->"
        return ports.range(of: pattern, options: .regularExpression) != nil
    }

    static func publishedHostPorts(_ ports: String) -> [Int] {
        let pattern = #"(?:^|[, ])(?:\[?[^, ]*\]?:)?(\d+)->"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(ports.startIndex..., in: ports)
        let values = expression.matches(in: ports, range: range).compactMap { match -> Int? in
            guard let capture = Range(match.range(at: 1), in: ports) else { return nil }
            return Int(ports[capture])
        }
        return Array(Set(values)).sorted()
    }

    private static func dockerExecutable() -> String? {
        ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
