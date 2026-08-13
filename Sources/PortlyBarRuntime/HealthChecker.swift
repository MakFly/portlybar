import Foundation
import Network

public enum HealthChecker {
    public static func check(port: Int, healthURL: String?, expectedStatus: Int?, timeout: TimeInterval = 2) async -> Bool {
        if let healthURL {
            let url: URL?
            if healthURL.hasPrefix("http://") || healthURL.hasPrefix("https://") {
                url = URL(string: healthURL)
            } else {
                let path = healthURL.hasPrefix("/") ? healthURL : "/\(healthURL)"
                url = URL(string: "http://127.0.0.1:\(port)\(path)")
            }
            guard let url else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else { return false }
                return expectedStatus.map { response.statusCode == $0 } ?? (200..<400).contains(response.statusCode)
            } catch {
                return false
            }
        }
        return await tcpCheck(port: port, timeout: timeout)
    }

    public static func checkHTTP(
        port: Int,
        path: String,
        expectedStatus: Int?,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: "http://127.0.0.1:\(port)\(normalizedPath)") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return expectedStatus.map { response.statusCode == $0 } ?? true
        } catch {
            return false
        }
    }

    private static func tcpCheck(port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "dev.portlybar.health.\(port)")
            let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            let result = OneShotHealthResult(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: result.finish(true)
                case .failed, .cancelled: result.finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { result.finish(false) }
        }
    }
}

private final class OneShotHealthResult: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Bool, Never>
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: value)
    }
}
