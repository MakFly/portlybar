import Foundation
import Network
import PortlyBarCore

public enum ControlServerError: LocalizedError {
    case invalidPort(Int)
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "Invalid control API port: \(port)."
        case .listenerFailed(let reason): return "Unable to start the loopback control API: \(reason)"
        }
    }
}

@MainActor
public final class ControlServer {
    private let supervisor: Supervisor
    private let port: Int
    private let openSettings: @MainActor () -> Void
    private let quitApplication: @MainActor () -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.portlybar.control")

    public init(
        supervisor: Supervisor,
        port: Int,
        openSettings: @escaping @MainActor () -> Void = {},
        quitApplication: @escaping @MainActor () -> Void = {}
    ) {
        self.supervisor = supervisor
        self.port = port
        self.openSettings = openSettings
        self.quitApplication = quitApplication
    }

    public func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ControlServerError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("[portlybar] control API failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private nonisolated func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private nonisolated func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            if let request = HTTPRequest(data: buffer) {
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel(); return }
                    let response = await self.route(request)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if complete || buffer.count >= 1_048_576 {
                connection.send(content: HTTPResponse.error(status: 400, message: "Malformed or incomplete HTTP request."), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                self?.receive(on: connection, accumulated: buffer)
            }
        }
    }

    private func route(_ request: HTTPRequest) async -> Data {
        do {
            if request.headers["origin"] != nil {
                return HTTPResponse.error(status: 403, message: "Browser-originated control requests are not allowed.")
            }
            if request.method == "POST", request.headers["content-type"]?.lowercased().hasPrefix("application/json") != true {
                return HTTPResponse.error(status: 415, message: "POST requests require Content-Type: application/json.")
            }

            switch (request.method, request.path) {
            case ("GET", "/ping"):
                return HTTPResponse.json(APIEnvelope(ok: true, data: PingResponse(version: Supervisor.version)))
            case ("GET", "/status"):
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.status()))
            case ("GET", "/config"):
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.configuration))
            case ("GET", "/logs"):
                let server = try request.requiredQuery("server")
                let tail = Int(request.query["tail"] ?? "200") ?? 200
                let lines = try supervisor.logs(server: server, tail: min(max(tail, 0), 10_000))
                return HTTPResponse.json(APIEnvelope(ok: true, data: LogsResponse(server: server, lines: lines)))
            case ("GET", "/temporary/status"):
                let id = try request.requiredQuery("id")
                return HTTPResponse.json(APIEnvelope(ok: true, data: try supervisor.temporaryStatus(id: id)))
            case ("GET", "/ports"):
                let ports = supervisor.ports()
                if let raw = request.query["port"], let port = Int(raw) {
                    return HTTPResponse.json(APIEnvelope<[ListeningPort]>(ok: true, data: ports.filter { $0.port == port }))
                }
                return HTTPResponse.json(APIEnvelope(ok: true, data: ports))
            case ("GET", "/docker"):
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.dockerContainers))
            case ("POST", "/start"), ("POST", "/stop"), ("POST", "/restart"):
                let action = try request.decode(ActionRequest.self)
                try applyAction(path: request.path, request: action)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.status()))
            case ("POST", "/temporary/run"):
                return HTTPResponse.json(APIEnvelope(ok: true, data: try supervisor.runTemporary(request.decode(TemporaryRunRequest.self))))
            case ("POST", "/temporary/http/start"):
                return HTTPResponse.json(APIEnvelope(ok: true, data: try await supervisor.startTemporaryHTTPServer(request.decode(TemporaryHTTPServerRequest.self))))
            case ("POST", "/temporary/stop"):
                let mutation = try request.decode(TemporaryJobRequest.self)
                return HTTPResponse.json(APIEnvelope(ok: true, data: try await supervisor.stopTemporary(id: mutation.id)))
            case ("POST", "/projects/add"):
                let mutation = try request.decode(ProjectMutationRequest.self)
                try supervisor.addProject(mutation.project)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.configuration))
            case ("POST", "/projects/update"):
                let mutation = try request.decode(ProjectMutationRequest.self)
                try supervisor.updateProject(mutation.project)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.configuration))
            case ("POST", "/projects/remove"):
                let mutation = try request.decode(RemoveRequest.self)
                guard let project = mutation.project else { throw HTTPRequestError.badRequest("project is required.") }
                try supervisor.removeProject(project)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.configuration))
            case ("POST", "/servers/add"):
                let mutation = try request.decode(ServerMutationRequest.self)
                try supervisor.addServer(project: mutation.project, server: mutation.server, start: mutation.start == true)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.configuration))
            case ("POST", "/servers/update"):
                let mutation = try request.decode(ServerMutationRequest.self)
                try supervisor.updateServer(project: mutation.project, server: mutation.server)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.configuration))
            case ("POST", "/servers/remove"):
                let mutation = try request.decode(RemoveRequest.self)
                guard let server = mutation.server else { throw HTTPRequestError.badRequest("server is required.") }
                try supervisor.removeServer(server)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.configuration))
            case ("POST", "/servers/take-over"):
                let mutation = try request.decode(ActionRequest.self)
                guard let server = mutation.server else { throw HTTPRequestError.badRequest("server is required.") }
                guard mutation.confirmed == true else { throw HTTPRequestError.badRequest("confirmed must be true before takeover sends SIGTERM.") }
                try await supervisor.takeOver(server: server)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.status()))
            case ("POST", "/ports/kill"):
                let mutation = try request.decode(PortRequest.self)
                guard mutation.confirmed == true else { throw HTTPRequestError.badRequest("confirmed must be true before signaling an external process.") }
                try supervisor.stopExternalPort(mutation)
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.ports()))
            case ("POST", "/memory-limit"):
                try supervisor.setMemoryLimit(request.decode(MemoryLimitRequest.self))
                return HTTPResponse.json(APIEnvelope(ok: true, data: supervisor.configuration))
            case ("POST", "/open"):
                openSettings()
                return HTTPResponse.json(APIEnvelope(ok: true, data: EmptyResponse()))
            case ("POST", "/quit"):
                let confirmation = try request.decode(ConfirmationRequest.self)
                guard confirmation.confirmed else { throw HTTPRequestError.badRequest("confirmed must be true to quit and stop active servers.") }
                Task { @MainActor [quitApplication] in
                    try? await Task.sleep(for: .milliseconds(150))
                    quitApplication()
                }
                return HTTPResponse.json(APIEnvelope(ok: true, data: EmptyResponse()))
            default:
                return HTTPResponse.error(status: 404, message: "Unknown route: \(request.method) \(request.path).")
            }
        } catch let error as HTTPRequestError {
            return HTTPResponse.error(status: 400, message: error.localizedDescription)
        } catch {
            return HTTPResponse.error(status: 409, message: error.localizedDescription)
        }
    }

    private func applyAction(path: String, request: ActionRequest) throws {
        if let server = request.server {
            if path == "/start" { try supervisor.start(server: server) }
            if path == "/stop" { try supervisor.stop(server: server) }
            if path == "/restart" { try supervisor.restart(server: server) }
            return
        }
        if let project = request.project {
            if path == "/start" { try supervisor.start(project: project) }
            if path == "/stop" { try supervisor.stop(project: project) }
            if path == "/restart" { try supervisor.restart(project: project) }
            return
        }
        if path == "/stop" { supervisor.stopAll(); return }
        throw HTTPRequestError.badRequest("server or project is required.")
    }
}

private enum HTTPRequestError: LocalizedError {
    case badRequest(String)
    var errorDescription: String? {
        if case .badRequest(let message) = self { return message }
        return nil
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let boundary = data.range(of: separator) else { return nil }
        let headerData = data[..<boundary.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestParts = first.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }
        method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return nil }
        path = components.path
        query = (components.queryItems ?? []).reduce(into: [:]) { result, item in
            result[item.name] = item.value ?? ""
        }
        headers = lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (
                line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            )
        }.reduce(into: [:]) { result, pair in result[pair.0] = pair.1 }
        let bodyStart = boundary.upperBound
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + expected else { return nil }
        body = data.subdata(in: bodyStart..<(bodyStart + expected))
    }

    func requiredQuery(_ name: String) throws -> String {
        guard let value = query[name], !value.isEmpty else { throw HTTPRequestError.badRequest("Missing query parameter: \(name).") }
        return value
    }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        do { return try APIClient.decoder.decode(type, from: body) }
        catch { throw HTTPRequestError.badRequest("Invalid JSON body: \(error.localizedDescription)") }
    }
}

private enum HTTPResponse {
    static func json<Value: Codable>(_ value: Value, status: Int = 200) -> Data {
        let body = (try? APIClient.encoder.encode(value)) ?? Data("{\"ok\":false,\"error\":\"Encoding failure.\"}".utf8)
        return response(status: status, body: body)
    }

    static func error(status: Int, message: String) -> Data {
        json(APIEnvelope<EmptyResponse>(ok: false, error: message), status: status)
    }

    private static func response(status: Int, body: Data) -> Data {
        let reason: String = switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 415: "Unsupported Media Type"
        default: "Error"
        }
        var result = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        result.append(body)
        return result
    }
}
