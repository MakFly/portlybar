import ArgumentParser
import Foundation
import PortlyBarCore

@main
struct PortlyBar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "portlybar",
        abstract: "Control the PortlyBar macOS server supervisor.",
        version: portlyBarVersion,
        subcommands: [
            Status.self, Start.self, Stop.self, Restart.self, Logs.self,
            Temp.self, HTTPServer.self, StopTemporary.self, Wait.self, AddProject.self, AddServer.self,
            UpdateServer.self, Remove.self, TakeOver.self, Port.self,
            KillPort.self, MemoryLimit.self, Open.self, Quit.self,
            Forever.self, Config.self,
        ],
        defaultSubcommand: Status.self
    )
}

private struct APIOptions: ParsableArguments {
    @Option(name: .long, help: "Loopback control API port.")
    var apiPort: Int = PortlyBarPaths.defaultAPIPort

    func client(launchIfNeeded: Bool = true) async throws -> APIClient {
        let client = APIClient(port: apiPort)
        do {
            let _: APIEnvelope<PingResponse> = try await client.get("/ping", as: APIEnvelope<PingResponse>.self)
            return client
        } catch where launchIfNeeded {
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["-a", "PortlyBar", "--background"]
            try opener.run()
            opener.waitUntilExit()
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(200))
                if (try? await client.get("/ping", as: APIEnvelope<PingResponse>.self)) != nil { return client }
            }
            throw ValidationError("PortlyBar did not start its control API on 127.0.0.1:\(apiPort). Install or launch PortlyBar.app first.")
        }
    }
}

private enum CLIOutput {
    static func json<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    static func stateSymbol(_ state: ServerState) -> String {
        switch state {
        case .running: return "●"
        case .starting: return "◐"
        case .unhealthy, .failed: return "!"
        case .stopping: return "◑"
        case .stopped: return "○"
        }
    }
}

private struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show server and temporary-job status.")
    @OptionGroup var api: APIOptions
    @Flag(name: .long, help: "Print all configured servers, including stopped servers.") var details = false
    @Flag(name: .long, help: "Print the complete JSON response.") var json = false

    func run() async throws {
        let client = try await api.client()
        let envelope = try await client.get("/status", as: APIEnvelope<SupervisorStatus>.self)
        guard let status = envelope.data else { throw ValidationError(envelope.error ?? "Missing status payload.") }
        if json { try CLIOutput.json(envelope); return }
        let servers = details ? status.servers : status.servers.filter { $0.state != .stopped || $0.lastError != nil }
        if servers.isEmpty && status.temporaryJobs.isEmpty { print("No active servers or problems."); return }
        for server in servers {
            let port = server.port.map { ":\($0)" } ?? ""
            let pid = server.pid.map { " pid \($0)" } ?? ""
            print("\(CLIOutput.stateSymbol(server.state)) \(server.selector)\(port) [\(server.state.rawValue)]\(pid)")
            if let error = server.lastError { print("  \(error)") }
        }
        for job in status.temporaryJobs {
            print("◇ temp \(job.id) \(job.name) [\(job.state.rawValue)]")
        }
    }
}

private struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a server or every server in a project.")
    @OptionGroup var api: APIOptions
    @Argument(help: "Server selector (project/server) or project name with --project.") var target: String
    @Flag(name: .long) var project = false
    @Flag(name: .long) var json = false
    func run() async throws { try await action(path: "/start", target: target, project: project, api: api, json: json) }
}

private struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop a server, project, or every supervised process.")
    @OptionGroup var api: APIOptions
    @Argument(help: "Server selector or project name. Omit with --all.") var target: String?
    @Flag(name: .long) var project = false
    @Flag(name: .long) var all = false
    @Flag(name: .long) var json = false
    func validate() throws {
        if all == (target != nil) { throw ValidationError("Provide exactly one target or --all.") }
    }
    func run() async throws { try await action(path: "/stop", target: target, project: project, api: api, json: json) }
}

private struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart a server or every server in a project.")
    @OptionGroup var api: APIOptions
    @Argument var target: String
    @Flag(name: .long) var project = false
    @Flag(name: .long) var json = false
    func run() async throws { try await action(path: "/restart", target: target, project: project, api: api, json: json) }
}

private func action(path: String, target: String?, project: Bool, api: APIOptions, json: Bool) async throws {
    let request = ActionRequest(server: project ? nil : target, project: project ? target : nil)
    let envelope = try await api.client().post(path, body: request, as: APIEnvelope<SupervisorStatus>.self)
    if json { try CLIOutput.json(envelope) }
    else if let error = envelope.error { throw ValidationError(error) }
    else { print("OK") }
}

private struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print recent output from a server or temporary job.")
    @OptionGroup var api: APIOptions
    @Argument var server: String
    @Option(name: .long) var tail: Int = 200
    @Flag(name: .long) var json = false
    func run() async throws {
        guard tail >= 0 && tail <= 10_000 else { throw ValidationError("--tail must be between 0 and 10000.") }
        var components = URLComponents()
        components.path = "/logs"
        components.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "tail", value: String(tail))]
        let envelope = try await api.client().get(components.string ?? "", as: APIEnvelope<LogsResponse>.self)
        if json { try CLIOutput.json(envelope) }
        else { print(envelope.data?.lines.joined(separator: "\n") ?? "") }
    }
}

private struct Temp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "temp",
        abstract: "Run a bounded command without creating a persistent project."
    )
    @OptionGroup var api: APIOptions
    @Argument(help: "Shell command executed through zsh -lc.") var command: String
    @Option(name: .long) var name: String = "temporary"
    @Option(name: .long, help: "Absolute working directory.") var path: String
    @Option(name: .long) var port: Int?
    @Option(name: .long, help: "Duration such as 30s, 20m, or 1h.") var timeout: String = "30m"
    @Option(name: .long, parsing: .upToNextOption, help: "Environment entries in KEY=VALUE form.") var env: [String] = []
    @Flag(name: .long) var json = false

    func run() async throws {
        guard path.hasPrefix("/") else { throw ValidationError("--path must be absolute.") }
        let seconds = try parseDuration(timeout)
        let environment = try parseEnvironment(env)
        let request = TemporaryRunRequest(name: name, command: command, directory: path, port: port, environment: environment, timeoutSeconds: seconds)
        let envelope = try await api.client().post("/temporary/run", body: request, as: APIEnvelope<TemporaryJobStatus>.self)
        if json { try CLIOutput.json(envelope) }
        else if let id = envelope.data?.id { print(id) }
        else { throw ValidationError(envelope.error ?? "Missing temporary job ID.") }
    }
}

private struct HTTPServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "http-server",
        abstract: "Run a temporary HTTP server on an automatically selected free port."
    )
    @OptionGroup var api: APIOptions
    @Argument(help: "Shell command executed through zsh -lc. It must read the PORT environment variable.") var command: String
    @Option(name: .long) var name: String = "http-server"
    @Option(name: .long, help: "Absolute working directory.") var path: String
    @Option(name: .customLong("min-port")) var minimumPort: Int = 49_152
    @Option(name: .customLong("max-port")) var maximumPort: Int = 65_535
    @Option(name: .long) var healthPath: String = "/"
    @Option(name: .long, help: "Required HTTP status. Any HTTP response is accepted when omitted.") var expectedStatus: Int?
    @Option(name: .long, help: "Startup duration such as 10s or 1m.") var startupTimeout: String = "30s"
    @Option(name: .long, help: "Maximum server lifetime such as 30m or 2h.") var timeout: String = "30m"
    @Option(name: .long, parsing: .upToNextOption, help: "Environment entries in KEY=VALUE form.") var env: [String] = []
    @Flag(name: .long) var json = false

    func validate() throws {
        guard path.hasPrefix("/") else { throw ValidationError("--path must be absolute.") }
        guard minimumPort >= 1, maximumPort <= 65_535, minimumPort <= maximumPort else {
            throw ValidationError("The port range must be within 1...65535 and min-port must not exceed max-port.")
        }
        if let expectedStatus, !(100...599).contains(expectedStatus) {
            throw ValidationError("--expected-status must be between 100 and 599.")
        }
    }

    func run() async throws {
        let request = TemporaryHTTPServerRequest(
            name: name,
            command: command,
            directory: path,
            environment: try parseEnvironment(env),
            minimumPort: minimumPort,
            maximumPort: maximumPort,
            healthPath: healthPath,
            expectedStatus: expectedStatus,
            startupTimeoutSeconds: try parseDuration(startupTimeout),
            timeoutSeconds: try parseDuration(timeout)
        )
        let envelope = try await api.client().post(
            "/temporary/http/start",
            body: request,
            as: APIEnvelope<TemporaryHTTPServerStatus>.self
        )
        guard let status = envelope.data else { throw ValidationError(envelope.error ?? "Missing HTTP server status.") }
        if json { try CLIOutput.json(envelope) }
        else {
            print(status.url)
            print("job \(status.job.id)")
        }
    }
}

private struct StopTemporary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop-temp",
        abstract: "Stop one temporary job supervised by PortlyBar."
    )
    @OptionGroup var api: APIOptions
    @Argument(help: "Temporary job ID returned by temp or http-server.") var id: String
    @Flag(name: .long) var json = false

    func run() async throws {
        let envelope = try await api.client().post(
            "/temporary/stop",
            body: TemporaryJobRequest(id: id),
            as: APIEnvelope<TemporaryJobStatus>.self
        )
        if json { try CLIOutput.json(envelope) }
        else if envelope.data != nil { print("OK") }
        else { throw ValidationError(envelope.error ?? "Missing temporary job status.") }
    }
}

private struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wait for a temporary job and return its exit code.")
    @OptionGroup var api: APIOptions
    @Argument var id: String
    @Flag(name: .long) var json = false
    func run() async throws {
        let client = try await api.client()
        while true {
            let path = "/temporary/status?id=\(id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id)"
            let envelope = try await client.get(path, as: APIEnvelope<TemporaryJobStatus>.self)
            guard let status = envelope.data else { throw ValidationError(envelope.error ?? "Missing job status.") }
            if status.state == .running { try await Task.sleep(for: .milliseconds(250)); continue }
            if json { try CLIOutput.json(envelope) }
            else {
                let logs = try await client.get("/logs?server=\(id)&tail=10000", as: APIEnvelope<LogsResponse>.self)
                print(logs.data?.lines.joined(separator: "\n") ?? "")
            }
            if status.state == .timedOut { throw ExitCode(124) }
            if let code = status.exitCode, code != 0 { throw ExitCode(code) }
            return
        }
    }
}

private struct AddProject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-project", abstract: "Register a project folder.")
    @OptionGroup var api: APIOptions
    @Option(name: .long) var name: String
    @Option(name: .long) var path: String
    @Option(name: .long) var icon: String = "shippingbox"
    @Option(name: .long) var color: String = "#0A84FF"
    @Flag(name: .long) var json = false
    func run() async throws {
        guard path.hasPrefix("/") else { throw ValidationError("--path must be absolute.") }
        let project = ProjectConfiguration(name: name, root: path, icon: icon, color: color)
        let envelope = try await api.client().post("/projects/add", body: ProjectMutationRequest(project: project), as: APIEnvelope<PortlyBarConfiguration>.self)
        if json { try CLIOutput.json(envelope) } else { print(project.id) }
    }
}

private struct AddServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-server", abstract: "Add a server to a project.")
    @OptionGroup var api: APIOptions
    @Option(name: .long) var project: String
    @Option(name: .long) var name: String
    @Option(name: .long) var command: String
    @Option(name: .long) var port: Int?
    @Option(name: .long) var directory: String?
    @Option(name: .long) var healthURL: String?
    @Option(name: .long) var healthStatus: Int?
    @Option(name: .long, parsing: .upToNextOption) var env: [String] = []
    @Flag(name: .long) var start = false
    @Flag(name: .long) var json = false
    func run() async throws {
        let server = ServerConfiguration(name: name, command: command, port: port, directory: directory, environment: try parseEnvironment(env), healthURL: healthURL, expectedHealthStatus: healthStatus)
        let envelope = try await api.client().post("/servers/add", body: ServerMutationRequest(project: project, server: server, start: start), as: APIEnvelope<PortlyBarConfiguration>.self)
        if json { try CLIOutput.json(envelope) } else { print(server.id) }
    }
}

private struct UpdateServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update-server", abstract: "Replace an existing server configuration.")
    @OptionGroup var api: APIOptions
    @Argument(help: "Existing project/server selector.") var selector: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var command: String?
    @Option(name: .long) var port: Int?
    @Option(name: .long) var directory: String?
    @Option(name: .long) var healthURL: String?
    @Option(name: .long) var healthStatus: Int?
    @Flag(name: .customLong("no-auto-restart")) var disableAutoRestart = false
    @Flag(name: .long) var json = false
    func run() async throws {
        let client = try await api.client()
        let configEnvelope = try await client.get("/config", as: APIEnvelope<PortlyBarConfiguration>.self)
        guard let config = configEnvelope.data, let (project, existing) = config.resolveServer(selector) else {
            throw ValidationError("Server not found or ambiguous: \(selector).")
        }
        var server = existing
        if let name { server.name = name }
        if let command { server.command = command }
        if let port { server.port = port }
        if let directory { server.directory = directory }
        if let healthURL { server.healthURL = healthURL }
        if let healthStatus { server.expectedHealthStatus = healthStatus }
        if disableAutoRestart { server.autoRestart = false }
        let envelope = try await client.post("/servers/update", body: ServerMutationRequest(project: project.id, server: server), as: APIEnvelope<PortlyBarConfiguration>.self)
        if json { try CLIOutput.json(envelope) } else { print("OK") }
    }
}

private struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a stopped server or project.")
    @OptionGroup var api: APIOptions
    @Argument var target: String
    @Flag(name: .long) var project = false
    @Flag(name: .long) var confirm = false
    func validate() throws { if !confirm { throw ValidationError("Removal requires --confirm.") } }
    func run() async throws {
        let path = project ? "/projects/remove" : "/servers/remove"
        let request = RemoveRequest(server: project ? nil : target, project: project ? target : nil)
        let envelope = try await api.client().post(path, body: request, as: APIEnvelope<PortlyBarConfiguration>.self)
        guard envelope.ok else { throw ValidationError(envelope.error ?? "Removal failed.") }
        print("OK")
    }
}

private struct TakeOver: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "take-over", abstract: "Stop an external listener and start the configured server.")
    @OptionGroup var api: APIOptions
    @Argument var server: String
    @Flag(name: .long) var confirm = false
    @Flag(name: .long) var json = false
    func validate() throws { if !confirm { throw ValidationError("Takeover sends SIGTERM and requires --confirm.") } }
    func run() async throws {
        let envelope = try await api.client().post("/servers/take-over", body: ActionRequest(server: server, confirmed: true), as: APIEnvelope<SupervisorStatus>.self)
        if json { try CLIOutput.json(envelope) } else { print("OK") }
    }
}

private struct Port: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the process listening on a port.")
    @OptionGroup var api: APIOptions
    @Argument var port: Int
    @Flag(name: .long) var json = false
    func run() async throws {
        let envelope = try await api.client().get("/ports?port=\(port)", as: APIEnvelope<[ListeningPort]>.self)
        if json { try CLIOutput.json(envelope); return }
        guard let occupant = envelope.data?.first else { print("Port \(port) is free."); return }
        print(":\(occupant.port) \(occupant.command) pid \(occupant.pid) \(occupant.user) [\(occupant.ownership.rawValue)]")
    }
}

private struct KillPort: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "kill-port", abstract: "Signal the validated owner of a port.")
    @OptionGroup var api: APIOptions
    @Argument var port: Int
    @Option(name: .long, help: "PID observed by the caller; prevents PID-reuse races.") var expectedPID: Int32
    @Flag(name: .long) var force = false
    @Flag(name: .long) var confirm = false
    @Flag(name: .long) var json = false
    func validate() throws { if !confirm { throw ValidationError("Stopping an external process requires --confirm.") } }
    func run() async throws {
        let request = PortRequest(port: port, expectedPID: expectedPID, force: force, confirmed: true)
        let envelope = try await api.client().post("/ports/kill", body: request, as: APIEnvelope<[ListeningPort]>.self)
        if json { try CLIOutput.json(envelope) } else { print("Signal sent to PID \(expectedPID).") }
    }
}

private struct MemoryLimit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory-limit", abstract: "Configure automatic project restarts by memory footprint.")
    @OptionGroup var api: APIOptions
    @Argument(help: "Size such as 5GB, 'off', or 'inherit' for a project.") var value: String
    @Option(name: .long) var project: String?
    @Flag(name: .long) var json = false
    func run() async throws {
        let normalized = value.lowercased()
        let mode: MemoryLimitMode
        let bytes: UInt64?
        if normalized == "off" { mode = .disabled; bytes = nil }
        else if normalized == "inherit" {
            guard project != nil else { throw ValidationError("'inherit' is valid only with --project.") }
            mode = .inherit; bytes = nil
        } else {
            guard let parsed = MemorySize.parse(value), parsed > 0 else { throw ValidationError("Invalid memory size: \(value).") }
            mode = .custom; bytes = parsed
        }
        let envelope = try await api.client().post("/memory-limit", body: MemoryLimitRequest(project: project, mode: mode, bytes: bytes), as: APIEnvelope<PortlyBarConfiguration>.self)
        if json { try CLIOutput.json(envelope) } else { print("OK") }
    }
}

private struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open PortlyBar settings.")
    @OptionGroup var api: APIOptions
    func run() async throws {
        let _: APIEnvelope<EmptyResponse> = try await api.client().post("/open", body: ConfirmationRequest(confirmed: true), as: APIEnvelope<EmptyResponse>.self)
    }
}

private struct Quit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quit PortlyBar and stop every supervised process.")
    @OptionGroup var api: APIOptions
    @Flag(name: .long) var confirm = false
    func validate() throws { if !confirm { throw ValidationError("Quitting stops every supervised process and requires --confirm.") } }
    func run() async throws {
        let _: APIEnvelope<EmptyResponse> = try await api.client().post("/quit", body: ConfirmationRequest(confirmed: true), as: APIEnvelope<EmptyResponse>.self)
    }
}

private struct Forever: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep PortlyBar available across macOS logins.",
        subcommands: [Enable.self, Disable.self, ForeverStatus.self]
    )

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install the per-user LaunchAgent.")
        @OptionGroup var api: APIOptions
        @Option(name: .long, help: "Absolute path to PortlyBar.app.") var appPath: String = "/Applications/PortlyBar.app"
        func run() async throws {
            let client = try await api.client()
            let status = try await client.get("/status", as: APIEnvelope<SupervisorStatus>.self)
            let selectors = status.data?.servers.filter { $0.pid != nil }.map(\.selector) ?? []
            try ForeverManager.enable(appPath: appPath, selectors: selectors)
            print("LaunchAgent enabled. \(selectors.count) active server(s) will be restored at login.")
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unload and remove the per-user LaunchAgent.")
        @Flag(name: .long) var confirm = false
        func validate() throws { if !confirm { throw ValidationError("Disabling the LaunchAgent requires --confirm.") } }
        func run() throws { try ForeverManager.disable(); print("LaunchAgent disabled.") }
    }

    struct ForeverStatus: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show LaunchAgent installation state.")
        func run() throws { print(ForeverManager.isInstalled ? "enabled" : "disabled") }
    }
}

private enum ForeverManager {
    static let label = "dev.portlybar.app"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func enable(appPath: String, selectors: [String]) throws {
        guard appPath.hasPrefix("/"), FileManager.default.fileExists(atPath: appPath) else {
            throw ValidationError("PortlyBar.app not found at \(appPath).")
        }
        try PortlyBarPaths.ensureDirectories()
        let resume = try JSONEncoder().encode(selectors)
        try resume.write(to: PortlyBarPaths.resumeFile, options: .atomic)
        let executable = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/PortlyBarApp").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--restore-session"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        _ = try runLaunchctl(["bootout", "gui/\(getuid())/\(label)"], allowFailure: true)
        try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    static func disable() throws {
        _ = try runLaunchctl(["bootout", "gui/\(getuid())/\(label)"], allowFailure: true)
        if isInstalled { try FileManager.default.removeItem(at: plistURL) }
        try? FileManager.default.removeItem(at: PortlyBarPaths.resumeFile)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String], allowFailure: Bool = false) throws -> Int32 {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0, !allowFailure {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ValidationError("launchctl failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return process.terminationStatus
    }
}

private struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the configuration path and contents.")
    @Flag(name: .long) var pathOnly = false
    func run() throws {
        print(PortlyBarPaths.configFile.path)
        if !pathOnly, FileManager.default.fileExists(atPath: PortlyBarPaths.configFile.path) {
            print(String(decoding: try Data(contentsOf: PortlyBarPaths.configFile), as: UTF8.self))
        }
    }
}

private func parseEnvironment(_ values: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for value in values {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            throw ValidationError("Environment entry must use KEY=VALUE: \(value)")
        }
        result[String(value[..<separator])] = String(value[value.index(after: separator)...])
    }
    return result
}

private func parseDuration(_ raw: String) throws -> Int {
    let value = raw.lowercased()
    let multiplier: Double
    let number: Substring
    if value.hasSuffix("ms") { multiplier = 0.001; number = value.dropLast(2) }
    else if value.hasSuffix("s") { multiplier = 1; number = value.dropLast() }
    else if value.hasSuffix("m") { multiplier = 60; number = value.dropLast() }
    else if value.hasSuffix("h") { multiplier = 3_600; number = value.dropLast() }
    else { multiplier = 1; number = Substring(value) }
    guard let amount = Double(number), amount > 0 else { throw ValidationError("Invalid duration: \(raw)") }
    return max(1, Int(ceil(amount * multiplier)))
}
