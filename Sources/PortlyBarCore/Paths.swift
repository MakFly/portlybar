import Foundation

public enum PortlyBarPaths {
    public static let appName = "PortlyBar"
    public static let defaultAPIPort = 7_738

    public static var configDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PORTLYBAR_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/portlybar", isDirectory: true)
    }

    public static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    public static var logsDirectory: URL {
        configDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public static var resumeFile: URL {
        configDirectory.appendingPathComponent("resume.json")
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )
    }
}
