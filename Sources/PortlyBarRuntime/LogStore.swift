import Foundation
import PortlyBarCore

public final class LogStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private var lines: [String] = []
    private var partialLine = ""
    private var maxLines: Int
    private var maxBytes: Int

    public init(serverID: String, maxLines: Int, maxFileMB: Int, directory: URL = PortlyBarPaths.logsDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = serverID.replacingOccurrences(of: "/", with: "-")
        self.fileURL = directory.appendingPathComponent("\(safeName).log")
        self.maxLines = max(100, maxLines)
        self.maxBytes = max(1, maxFileMB) * 1_000_000
    }

    public func append(bytes: ArraySlice<UInt8>) {
        append(text: String(decoding: bytes, as: UTF8.self))
    }

    public func append(text: String) {
        lock.lock()
        defer { lock.unlock() }
        partialLine += text.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = partialLine.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return }
        partialLine = parts.last ?? ""
        let completed = Array(parts.dropLast())
        lines.append(contentsOf: completed)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        appendToFile(completed)
    }

    public func tail(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let complete = lines.suffix(max(0, count))
        return partialLine.isEmpty ? Array(complete) : Array(complete) + [partialLine]
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll(keepingCapacity: true)
        partialLine = ""
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
    }

    public func updateLimits(maxLines: Int, maxFileMB: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.maxLines = max(100, maxLines)
        maxBytes = max(1, maxFileMB) * 1_000_000
        if lines.count > self.maxLines {
            lines.removeFirst(lines.count - self.maxLines)
        }
    }

    private func appendToFile(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        rotateIfNeeded(incomingBytes: newLines.reduce(0) { $0 + $1.utf8.count + 1 })
        let data = Data((newLines.joined(separator: "\n") + "\n").utf8)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // File persistence is best-effort; in-memory logs remain available.
        }
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        let current = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard current + incomingBytes > maxBytes else { return }
        let previous = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }
}
