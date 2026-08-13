import Darwin
import Foundation

public enum PortAllocatorError: LocalizedError, Equatable {
    case invalidRange(Int, Int)
    case noAvailablePort(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRange(let minimum, let maximum):
            return "Invalid port range: \(minimum)...\(maximum)."
        case .noAvailablePort(let minimum, let maximum):
            return "No free TCP port is available in \(minimum)...\(maximum)."
        }
    }
}

public enum PortAllocator {
    public static func availablePort(minimum: Int, maximum: Int) throws -> Int {
        guard minimum >= 1, maximum <= 65_535, minimum <= maximum else {
            throw PortAllocatorError.invalidRange(minimum, maximum)
        }
        let count = maximum - minimum + 1
        let start = Int.random(in: 0..<count)
        for offset in 0..<count {
            let candidate = minimum + ((start + offset) % count)
            if canBind(candidate) { return candidate }
        }
        throw PortAllocatorError.noAvailablePort(minimum, maximum)
    }

    public static func canBind(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
