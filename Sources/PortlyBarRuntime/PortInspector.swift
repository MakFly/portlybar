import Darwin
import Foundation
import PortlyBarCore

public enum PortInspectorError: LocalizedError, Equatable {
    case portFree(Int)
    case listenerChanged(port: Int, expected: Int32, actual: Int32)
    case protectedProcess(Int32)
    case signalFailed(pid: Int32, signal: Int32)

    public var errorDescription: String? {
        switch self {
        case .portFree(let port): return "Port \(port) is already free."
        case .listenerChanged(let port, let expected, let actual):
            return "Listener on port \(port) changed from PID \(expected) to PID \(actual). Refresh and try again."
        case .protectedProcess(let pid): return "PID \(pid) is owned by another user or protected by macOS."
        case .signalFailed(let pid, let signal): return "Unable to send signal \(signal) to PID \(pid)."
        }
    }
}

public enum PortInspector {
    public static func listeners(managed: [Int32: String] = [:]) -> [ListeningPort] {
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcLn"])
        guard !output.isEmpty else { return [] }

        var rows: [(Int, Int32, String, String)] = []
        var pid: Int32?
        var command = ""
        var user = ""
        var ports = Set<Int>()
        func flush() {
            guard let pid else { return }
            for port in ports { rows.append((port, pid, command.isEmpty ? "unknown" : command, user)) }
        }
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": flush(); pid = Int32(value); command = ""; user = ""; ports.removeAll(keepingCapacity: true)
            case "c": command = value
            case "L": user = value
            case "n": if let port = portNumber(value) { ports.insert(port) }
            default: break
            }
        }
        flush()
        let directories = workingDirectories(Set(rows.map(\.1)))
        let currentUser = NSUserName()
        return rows.filter { _, _, command, _ in shouldInclude(command: command) }.map { port, pid, command, user in
            let ownership: PortOwnership = managed[pid] != nil ? .managed : (user == currentUser ? .external : .protected)
            return ListeningPort(
                port: port,
                pid: pid,
                command: command,
                user: user,
                workingDirectory: directories[pid],
                ownership: ownership,
                managedServerID: managed[pid]
            )
        }.sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
    }

    static func shouldInclude(command: String) -> Bool {
        let normalized = command.lowercased()
        return !normalized.hasPrefix("orbstack") && !normalized.hasPrefix("controlcenter")
    }

    public static func occupant(of port: Int, managed: [Int32: String] = [:]) -> ListeningPort? {
        listeners(managed: managed).first { $0.port == port }
    }

    public static func stop(port: Int, expectedPID: Int32, force: Bool = false) throws {
        guard let current = occupant(of: port) else { throw PortInspectorError.portFree(port) }
        guard current.pid == expectedPID else {
            throw PortInspectorError.listenerChanged(port: port, expected: expectedPID, actual: current.pid)
        }
        if let container = DockerPortInspector.container(publishing: port) {
            guard !force else {
                throw NSError(
                    domain: "PortlyBarDocker",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Force-killing Docker Desktop is forbidden. Stop the mapped container normally."]
                )
            }
            try DockerPortInspector.stop(container)
            return
        }
        guard current.user == NSUserName() else { throw PortInspectorError.protectedProcess(current.pid) }
        let signal = force ? SIGKILL : SIGTERM
        guard Darwin.kill(current.pid, signal) == 0 else {
            throw PortInspectorError.signalFailed(pid: current.pid, signal: signal)
        }
    }

    private static func workingDirectories(_ pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.sorted().map(String.init).joined(separator: ",")
        let output = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-Fpn"])
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" { pid = Int32(value) }
            if tag == "n", let pid { result[pid] = value }
        }
        return result
    }

    private static func portNumber(_ endpoint: String) -> Int? {
        let local = endpoint.split(separator: "->", maxSplits: 1).first.map(String.init) ?? endpoint
        guard let separator = local.lastIndex(of: ":") else { return nil }
        let raw = local[local.index(after: separator)...]
        guard let port = Int(raw), (1...65_535).contains(port) else { return nil }
        return port
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return "" }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
