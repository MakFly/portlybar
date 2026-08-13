import Foundation

public struct APIEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public var ok: Bool
    public var data: Value?
    public var error: String?

    public init(ok: Bool, data: Value? = nil, error: String? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
    }
}

public struct EmptyResponse: Codable, Hashable, Sendable {
    public init() {}
}

public struct PingResponse: Codable, Hashable, Sendable {
    public var version: String
    public init(version: String) { self.version = version }
}

public struct LogsResponse: Codable, Hashable, Sendable {
    public var server: String
    public var lines: [String]
    public init(server: String, lines: [String]) {
        self.server = server
        self.lines = lines
    }
}

public struct ConfirmationRequest: Codable, Hashable, Sendable {
    public var confirmed: Bool
    public init(confirmed: Bool) { self.confirmed = confirmed }
}

public struct ActionRequest: Codable, Hashable, Sendable {
    public var server: String?
    public var project: String?
    public var confirmed: Bool?

    public init(server: String? = nil, project: String? = nil, confirmed: Bool? = nil) {
        self.server = server
        self.project = project
        self.confirmed = confirmed
    }
}

public struct TemporaryRunRequest: Codable, Hashable, Sendable {
    public var name: String
    public var command: String
    public var directory: String
    public var port: Int?
    public var environment: [String: String]
    public var timeoutSeconds: Int

    public init(
        name: String,
        command: String,
        directory: String,
        port: Int? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Int
    ) {
        self.name = name
        self.command = command
        self.directory = directory
        self.port = port
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct TemporaryHTTPServerRequest: Codable, Hashable, Sendable {
    public var name: String
    public var command: String
    public var directory: String
    public var environment: [String: String]
    public var minimumPort: Int
    public var maximumPort: Int
    public var healthPath: String
    public var expectedStatus: Int?
    public var startupTimeoutSeconds: Int
    public var timeoutSeconds: Int

    public init(
        name: String,
        command: String,
        directory: String,
        environment: [String: String] = [:],
        minimumPort: Int = 49_152,
        maximumPort: Int = 65_535,
        healthPath: String = "/",
        expectedStatus: Int? = nil,
        startupTimeoutSeconds: Int = 30,
        timeoutSeconds: Int = 1_800
    ) {
        self.name = name
        self.command = command
        self.directory = directory
        self.environment = environment
        self.minimumPort = minimumPort
        self.maximumPort = maximumPort
        self.healthPath = healthPath
        self.expectedStatus = expectedStatus
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct TemporaryHTTPServerStatus: Codable, Hashable, Sendable {
    public var job: TemporaryJobStatus
    public var port: Int
    public var url: String

    public init(job: TemporaryJobStatus, port: Int, url: String) {
        self.job = job
        self.port = port
        self.url = url
    }
}

public struct TemporaryJobRequest: Codable, Hashable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct ProjectMutationRequest: Codable, Hashable, Sendable {
    public var project: ProjectConfiguration
    public init(project: ProjectConfiguration) { self.project = project }
}

public struct ServerMutationRequest: Codable, Hashable, Sendable {
    public var project: String
    public var server: ServerConfiguration
    public var start: Bool?
    public init(project: String, server: ServerConfiguration, start: Bool? = nil) {
        self.project = project
        self.server = server
        self.start = start
    }
}

public struct RemoveRequest: Codable, Hashable, Sendable {
    public var server: String?
    public var project: String?
    public init(server: String? = nil, project: String? = nil) {
        self.server = server
        self.project = project
    }
}

public struct PortRequest: Codable, Hashable, Sendable {
    public var port: Int
    public var expectedPID: Int32?
    public var force: Bool?
    public var confirmed: Bool?
    public init(port: Int, expectedPID: Int32? = nil, force: Bool? = nil, confirmed: Bool? = nil) {
        self.port = port
        self.expectedPID = expectedPID
        self.force = force
        self.confirmed = confirmed
    }
}

public struct MemoryLimitRequest: Codable, Hashable, Sendable {
    public var project: String?
    public var mode: MemoryLimitMode
    public var bytes: UInt64?
    public init(project: String? = nil, mode: MemoryLimitMode, bytes: UInt64? = nil) {
        self.project = project
        self.mode = mode
        self.bytes = bytes
    }
}

public final class APIClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(port: Int = PortlyBarPaths.defaultAPIPort, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
    }

    public func get<Response: Decodable>(_ path: String, as type: Response.Type) async throws -> Response {
        let url = try makeURL(path)
        let (data, response) = try await session.data(from: url)
        return try decode(data: data, response: response, as: type)
    }

    public func post<Request: Encodable, Response: Decodable>(
        _ path: String,
        body: Request,
        as type: Response.Type
    ) async throws -> Response {
        let url = try makeURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response, as: type)
    }

    private func decode<Response: Decodable>(data: Data, response: URLResponse, as type: Response.Type) throws -> Response {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? Self.decoder.decode(APIEnvelope<EmptyResponse>.self, from: data).error)
                ?? "PortlyBar API returned HTTP \(http.statusCode)."
            throw NSError(domain: "PortlyBarAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try Self.decoder.decode(type, from: data)
    }

    private func makeURL(_ path: String) throws -> URL {
        guard let url = URL(string: path.hasPrefix("/") ? path : "/\(path)", relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        return url
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
