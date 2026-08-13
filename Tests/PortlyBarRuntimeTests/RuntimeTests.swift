import Darwin
import Foundation
import Network
import PortlyBarCore
import Testing
@testable import PortlyBarRuntime

@Test func logStoreKeepsTailAndRotates() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LogStore(serverID: "demo/web", maxLines: 100, maxFileMB: 1, directory: directory)
    for index in 0..<140 { store.append(text: "line \(index)\n") }
    #expect(store.tail(3) == ["line 137", "line 138", "line 139"])
    store.append(text: String(repeating: "x", count: 1_100_000) + "\n")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("demo-web.log.1").path))
}

@Test func dockerPortMappingParserIsExact() {
    #expect(DockerPortInspector.publishes("0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp", port: 3000))
    #expect(!DockerPortInspector.publishes("0.0.0.0:13000->3000/tcp", port: 3000))
    #expect(DockerPortInspector.publishedHostPorts("0.0.0.0:1025->1025/tcp, [::]:1025->1025/tcp, 0.0.0.0:8025->8025/tcp") == [1025, 8025])
    #expect(DockerPortInspector.publishedHostPorts("5432/tcp").isEmpty)
}

@Test func dockerContainerLineParserReadsState() {
    let running = DockerPortInspector.parse(
        "abc123\tinfra-postgres\tpostgres:16\trunning\tUp 2 hours (healthy)\t0.0.0.0:5432->5432/tcp\tinfra\tpostgres"
    )
    #expect(running?.state == .running)
    #expect(running?.state.isRunning == true)
    #expect(running?.publishedPorts == [5432])
    #expect(running?.project == "infra")
    #expect(running?.service == "postgres")

    let stopped = DockerPortInspector.parse(
        "def456\tinfra-mailpit\taxllent/mailpit\texited\tExited (0) 3 days ago\t\t\t"
    )
    #expect(stopped?.state == .exited)
    #expect(stopped?.state.isRunning == false)
    #expect(stopped?.publishedPorts.isEmpty == true)
    #expect(stopped?.project == nil)
    #expect(stopped?.service == nil)

    #expect(DockerPortInspector.parse("truncated\tline") == nil)
}

@Test func portInspectorFiltersSystemInfrastructure() {
    #expect(!PortInspector.shouldInclude(command: "OrbStack Helper"))
    #expect(!PortInspector.shouldInclude(command: "ControlCenter"))
    #expect(PortInspector.shouldInclude(command: "node"))
    #expect(PortInspector.shouldInclude(command: "bun"))
}

@Test func healthCheckerSeesARealTCPListener() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = AsyncValue<UInt16>()
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port?.rawValue { ready.set(port) }
    }
    listener.newConnectionHandler = { connection in connection.start(queue: .global()); connection.cancel() }
    listener.start(queue: .global())
    let port = try await ready.value(timeout: 3)
    #expect(await HealthChecker.check(port: Int(port), healthURL: nil, expectedStatus: nil))
    listener.cancel()
}

@Test func portAllocatorRejectsAnOccupiedPort() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = AsyncValue<UInt16>()
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port?.rawValue { ready.set(port) }
    }
    listener.newConnectionHandler = { connection in connection.start(queue: .global()); connection.cancel() }
    listener.start(queue: .global())
    let port = Int(try await ready.value(timeout: 3))
    defer { listener.cancel() }
    #expect(!PortAllocator.canBind(port))
    #expect(throws: PortAllocatorError.self) {
        try PortAllocator.availablePort(minimum: port, maximum: port)
    }
}

@Test func HTTPHealthAcceptsAnyRealHTTPStatus() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = AsyncValue<UInt16>()
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port?.rawValue { ready.set(port) }
    }
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
            let response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    listener.start(queue: .global())
    let port = Int(try await ready.value(timeout: 3))
    defer { listener.cancel() }
    #expect(await HealthChecker.checkHTTP(port: port, path: "/missing", expectedStatus: nil))
    #expect(!(await HealthChecker.checkHTTP(port: port, path: "/missing", expectedStatus: 200)))
}

@Test @MainActor func temporaryHTTPServerStartsAndStopsOnItsAllocatedPort() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ConfigStore(url: directory.appendingPathComponent("config.json"))
    let supervisor = try Supervisor(store: store)
    let status = try await supervisor.startTemporaryHTTPServer(TemporaryHTTPServerRequest(
        name: "test-http",
        command: "/usr/bin/python3 -m http.server \"$PORT\" --bind \"$HOST\"",
        directory: directory.path,
        healthPath: "/missing",
        startupTimeoutSeconds: 10,
        timeoutSeconds: 30
    ))
    #expect(status.job.state == .running)
    #expect(status.url == "http://127.0.0.1:\(status.port)/missing")
    #expect(!PortAllocator.canBind(status.port))

    let stopped = try await supervisor.stopTemporary(id: status.job.id)
    #expect(stopped.pid == nil)
    #expect(stopped.state == .stopped)
    for _ in 0..<20 {
        if PortInspector.occupant(of: status.port) == nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(PortInspector.occupant(of: status.port) == nil)
}

@Test @MainActor func temporaryHTTPServerCleansUpAfterStartupTimeout() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ConfigStore(url: directory.appendingPathComponent("config.json"))
    let supervisor = try Supervisor(store: store)
    await #expect(throws: Error.self) {
        try await supervisor.startTemporaryHTTPServer(TemporaryHTTPServerRequest(
            name: "never-http",
            command: "while true; do sleep 1; done",
            directory: directory.path,
            startupTimeoutSeconds: 1,
            timeoutSeconds: 30
        ))
    }
    #expect(!supervisor.hasActiveProcesses)
}

@Test func portInspectorDiscoversARealTCPListener() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = AsyncValue<UInt16>()
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port?.rawValue { ready.set(port) }
    }
    listener.newConnectionHandler = { connection in connection.start(queue: .global()); connection.cancel() }
    listener.start(queue: .global())
    let port = try await ready.value(timeout: 3)
    #expect(PortInspector.listeners().contains { $0.port == Int(port) && $0.pid == getpid() })
    listener.cancel()
}

@Test @MainActor func ptyProcessCapturesOutputAndExitCode() async throws {
    let delegate = PTYDelegate()
    let process = PTYProcess(delegate: delegate)
    try process.start(
        command: "printf '\\033[32mhello\\033[0m\\n'",
        directory: "/tmp",
        environment: ProcessInfo.processInfo.environment
    )
    let result = try await delegate.result.value(timeout: 5)
    #expect(result.exitCode == 0)
    let output = await delegate.waitForOutput(containing: "\u{1B}[32mhello\u{1B}[0m")
    #expect(output.contains("\u{1B}[32mhello\u{1B}[0m"))
}

@Test @MainActor func ptyProcessReportsTerminationAfterStoppingProcessGroup() async throws {
    let delegate = PTYDelegate()
    let process = PTYProcess(delegate: delegate)
    try process.start(
        command: "while true; do sleep 1; done",
        directory: "/tmp",
        environment: ProcessInfo.processInfo.environment
    )
    #expect(process.pid != nil)
    process.terminate()
    let result = try await delegate.result.value(timeout: 5)
    #expect(result.exitCode == 143)
    #expect(process.pid == nil)
}

@Test @MainActor func temporaryJobReturnsItsRealExitCode() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ConfigStore(url: directory.appendingPathComponent("config.json"))
    let supervisor = try Supervisor(store: store)
    let status = try supervisor.runTemporary(TemporaryRunRequest(
        name: "exit-seven",
        command: "echo done; exit 7",
        directory: "/tmp",
        timeoutSeconds: 5
    ))
    for _ in 0..<50 {
        if try supervisor.temporaryStatus(id: status.id).state != .running { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let finished = try supervisor.temporaryStatus(id: status.id)
    #expect(finished.state == .failed)
    #expect(finished.exitCode == 7)

    // The PTY drains on its own queue, so the exit can be observed before the
    // last line reaches the log store.
    var logs: [String] = []
    for _ in 0..<50 {
        logs = try supervisor.logs(server: status.id, tail: 10)
        if logs.contains("done") { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(logs.contains("done"))
}

@Test @MainActor func controlAPIRejectsBrowserOrigins() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = PortlyBarConfiguration()
    config.apiPort = Int(try availableTCPPort())
    let store = try ConfigStore(url: directory.appendingPathComponent("config.json"))
    try store.replace(with: config)
    let supervisor = try Supervisor(store: store)
    let server = ControlServer(supervisor: supervisor, port: config.apiPort)
    try server.start()
    defer { server.stop() }
    try await Task.sleep(for: .milliseconds(100))

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.apiPort)/ping")!)
    request.setValue("http://localhost:3000", forHTTPHeaderField: "Origin")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 403)
    let envelope = try APIClient.decoder.decode(APIEnvelope<EmptyResponse>.self, from: data)
    #expect(envelope.ok == false)
}

private final class PTYDelegate: PTYProcessDelegate, @unchecked Sendable {
    struct Result { let output: String; let exitCode: Int32? }
    let result = AsyncValue<Result>()
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    var output: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// SwiftTerm does not guarantee the final read lands before the exit
    /// callback, so tests wait for output rather than snapshotting it on exit.
    func waitForOutput(containing needle: String, timeout: TimeInterval = 5) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if output.contains(needle) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return output
    }

    func ptyProcess(_ process: PTYProcess, received bytes: ArraySlice<UInt8>) {
        lock.lock(); self.bytes.append(contentsOf: bytes); lock.unlock()
    }
    func ptyProcess(_ process: PTYProcess, terminatedWith exitCode: Int32?) {
        lock.lock(); let output = String(decoding: bytes, as: UTF8.self); lock.unlock()
        result.set(Result(output: output, exitCode: exitCode))
    }
}

private final class AsyncValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed = false
    func set(_ value: Value) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        if let continuation {
            completed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            stored = value
            lock.unlock()
        }
    }
    func value(timeout: TimeInterval) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let stored {
                completed = true
                lock.unlock()
                continuation.resume(returning: stored)
                return
            }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.lock.lock()
                guard !self.completed, let continuation = self.continuation else { self.lock.unlock(); return }
                self.completed = true
                self.continuation = nil
                self.lock.unlock()
                continuation.resume(throwing: NSError(domain: "PortlyBarTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for async value."]))
            }
        }
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("portlybar-tests-\(UUID().uuidString)", isDirectory: true)
}

private func availableTCPPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let read = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard read == 0 else { throw POSIXError(.EIO) }
    return UInt16(bigEndian: address.sin_port)
}
