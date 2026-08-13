import CryptoKit
import Foundation

public struct AgentSkillSyncReport: Equatable, Sendable {
    public var installed: [String]
    public var updated: [String]
    public var unchanged: [String]
    public var conflicts: [String]
    public var cliPath: String?
    public var legacyRulesRemoved: Bool

    public init(
        installed: [String] = [],
        updated: [String] = [],
        unchanged: [String] = [],
        conflicts: [String] = [],
        cliPath: String? = nil,
        legacyRulesRemoved: Bool = false
    ) {
        self.installed = installed
        self.updated = updated
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.cliPath = cliPath
        self.legacyRulesRemoved = legacyRulesRemoved
    }

    public var summary: String {
        var lines: [String] = []
        if !installed.isEmpty { lines.append("Installed:\n\(installed.joined(separator: "\n"))") }
        if !updated.isEmpty { lines.append("Updated:\n\(updated.joined(separator: "\n"))") }
        if !unchanged.isEmpty { lines.append("Already current: \(unchanged.count)") }
        if let cliPath { lines.append("CLI: \(cliPath)") }
        if legacyRulesRemoved { lines.append("Removed the legacy PortlyBar AGENTS.md block.") }
        if !conflicts.isEmpty { lines.append("Not overwritten because of local content:\n\(conflicts.joined(separator: "\n"))") }
        return lines.isEmpty ? "No compatible agent installation was detected." : lines.joined(separator: "\n\n")
    }
}

public enum AgentSkillInstaller {
    public static let skillNames = ["portlybar", "portlybar-http-server"]
    private static let markerStart = "<!-- PORTLYBAR AGENT RULES START -->"
    private static let markerEnd = "<!-- PORTLYBAR AGENT RULES END -->"

    private struct Receipt: Codable {
        var skillHashes: [String: String] = [:]
        var cliTarget: String?
    }

    public static func synchronize(
        sourceRoot: URL,
        homeDirectory: URL,
        cliExecutable: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> AgentSkillSyncReport {
        for skillName in skillNames {
            let skill = sourceRoot.appendingPathComponent(skillName, isDirectory: true)
            guard fileManager.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path) else {
                throw NSError(
                    domain: "PortlyBarAgents",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Bundled agent skill is missing: \(skill.path)"]
                )
            }
        }

        let agentsRoot = homeDirectory.appendingPathComponent(".agents", isDirectory: true)
        try fileManager.createDirectory(at: agentsRoot, withIntermediateDirectories: true)
        let receiptURL = agentsRoot.appendingPathComponent(".portlybar-skills.json")
        var receipt = try loadReceipt(at: receiptURL, fileManager: fileManager)
        var report = AgentSkillSyncReport()

        for root in detectedSkillRoots(homeDirectory: homeDirectory, fileManager: fileManager) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            for skillName in skillNames {
                let source = sourceRoot.appendingPathComponent(skillName, isDirectory: true)
                let destination = root.appendingPathComponent(skillName, isDirectory: true)
                let key = destination.standardizedFileURL.path
                let sourceHash = try directoryHash(source, fileManager: fileManager)

                if (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                    report.conflicts.append(destination.path)
                    continue
                }

                if !fileManager.fileExists(atPath: destination.path) {
                    try replaceDirectory(at: destination, with: source, fileManager: fileManager)
                    receipt.skillHashes[key] = sourceHash
                    report.installed.append(destination.path)
                    continue
                }

                let destinationHash = try directoryHash(destination, fileManager: fileManager)
                if destinationHash == sourceHash {
                    receipt.skillHashes[key] = sourceHash
                    report.unchanged.append(destination.path)
                } else if receipt.skillHashes[key] == destinationHash {
                    try replaceDirectory(at: destination, with: source, fileManager: fileManager)
                    receipt.skillHashes[key] = sourceHash
                    report.updated.append(destination.path)
                } else {
                    report.conflicts.append(destination.path)
                }
            }
        }

        if let cliExecutable, fileManager.isExecutableFile(atPath: cliExecutable.path) {
            report.cliPath = try synchronizeCLI(
                executable: cliExecutable,
                homeDirectory: homeDirectory,
                receipt: &receipt,
                conflicts: &report.conflicts,
                fileManager: fileManager
            )
        }
        report.legacyRulesRemoved = try removeLegacyRules(homeDirectory: homeDirectory, fileManager: fileManager)
        try saveReceipt(receipt, at: receiptURL, fileManager: fileManager)
        report.installed.sort()
        report.updated.sort()
        report.unchanged.sort()
        report.conflicts.sort()
        return report
    }

    private static func detectedSkillRoots(homeDirectory: URL, fileManager: FileManager) -> [URL] {
        var roots = [homeDirectory.appendingPathComponent(".agents/skills", isDirectory: true)]
        let candidates: [(String, String)] = [
            (".claude", ".claude/skills"),
            (".codex", ".codex/skills"),
            (".config/opencode", ".config/opencode/skills"),
            (".gemini", ".gemini/skills"),
            (".cursor", ".cursor/skills"),
        ]
        for (detector, skillRoot) in candidates {
            if fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(detector).path) {
                roots.append(homeDirectory.appendingPathComponent(skillRoot, isDirectory: true))
            }
        }
        return roots
    }

    private static func synchronizeCLI(
        executable: URL,
        homeDirectory: URL,
        receipt: inout Receipt,
        conflicts: inout [String],
        fileManager: FileManager
    ) throws -> String? {
        let binDirectory = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        let destination = binDirectory.appendingPathComponent("portlybar")
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let target = executable.standardizedFileURL.path

        let existingLink = try? fileManager.destinationOfSymbolicLink(atPath: destination.path)
        if !fileManager.fileExists(atPath: destination.path), existingLink == nil {
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            receipt.cliTarget = target
            return destination.path
        }

        if let existing = existingLink {
            if existing == target { receipt.cliTarget = target; return destination.path }
            if receipt.cliTarget == existing {
                try fileManager.removeItem(at: destination)
                try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
                receipt.cliTarget = target
                return destination.path
            }
        }
        conflicts.append(destination.path)
        return nil
    }

    private static func removeLegacyRules(homeDirectory: URL, fileManager: FileManager) throws -> Bool {
        let instructions = homeDirectory.appendingPathComponent(".agents/AGENTS.md")
        guard fileManager.fileExists(atPath: instructions.path) else { return false }
        let existing = try String(contentsOf: instructions, encoding: .utf8)
        let start = existing.range(of: markerStart)
        let end = existing.range(of: markerEnd)
        guard start != nil || end != nil else { return false }
        guard let start, let end, start.lowerBound < end.upperBound else {
            throw NSError(
                domain: "PortlyBarAgents",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The legacy PortlyBar block in \(instructions.path) is malformed."]
            )
        }
        var updated = existing
        updated.removeSubrange(start.lowerBound..<end.upperBound)
        updated = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        if !updated.isEmpty { updated.append("\n") }
        try updated.write(to: instructions, atomically: true, encoding: .utf8)
        return true
    }

    private static func replaceDirectory(at destination: URL, with source: URL, fileManager: FileManager) throws {
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".portlybar-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: source, to: staging)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func directoryHash(_ directory: URL, fileManager: FileManager) throws -> String {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw NSError(
                domain: "PortlyBarAgents",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to enumerate agent skill: \(directory.path)"]
            )
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        var hasher = SHA256()
        for file in files {
            let relative = String(file.path.dropFirst(directory.path.count))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func loadReceipt(at url: URL, fileManager: FileManager) throws -> Receipt {
        guard fileManager.fileExists(atPath: url.path) else { return Receipt() }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
    }

    private static func saveReceipt(_ receipt: Receipt, at url: URL, fileManager: FileManager) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }
}
