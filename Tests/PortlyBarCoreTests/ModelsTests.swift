import Foundation
import Testing
@testable import PortlyBarCore

@Test func resolvesQualifiedAndUniqueServers() {
    let web = ServerConfiguration(id: "web-id", name: "web", command: "npm run dev", port: 3000)
    let api = ServerConfiguration(id: "api-id", name: "api", command: "npm run api", port: 3001)
    let config = PortlyBarConfiguration(projects: [
        ProjectConfiguration(id: "demo-id", name: "Demo", root: "/tmp/demo", servers: [web, api])
    ])

    #expect(config.resolveServer("Demo/web")?.1.id == "web-id")
    #expect(config.resolveServer("api")?.1.id == "api-id")
    #expect(config.resolveProject("demo")?.id == "demo-id")
}

@Test func validatesDuplicateNamesAndPorts() throws {
    let duplicate = PortlyBarConfiguration(projects: [
        ProjectConfiguration(name: "Demo", root: "/tmp/a"),
        ProjectConfiguration(name: "demo", root: "/tmp/b"),
    ])
    #expect(throws: ConfigurationError.self) { try ConfigStore.validate(duplicate) }

    let badPort = PortlyBarConfiguration(projects: [
        ProjectConfiguration(
            name: "Demo",
            root: "/tmp/demo",
            servers: [ServerConfiguration(name: "web", command: "serve", port: 70_000)]
        )
    ])
    #expect(throws: ConfigurationError.self) { try ConfigStore.validate(badPort) }
}

@Test func persistsConfigurationAtomically() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portlybar-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    let store = try ConfigStore(url: url)
    var config = store.configuration
    config.projects.append(ProjectConfiguration(name: "Demo", root: "/tmp/demo"))
    try store.replace(with: config)

    let loaded = try ConfigStore(url: url)
    #expect(loaded.configuration.projects.first?.name == "Demo")
}

@Test(arguments: [("5GB", UInt64(5_000_000_000)), ("1.5GiB", UInt64(1_610_612_736)), ("512MB", UInt64(512_000_000))])
func parsesMemorySizes(input: String, expected: UInt64) {
    #expect(MemorySize.parse(input) == expected)
}

@Test func synchronizesAgentSkillsWithoutOverwritingLocalChanges() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portlybar-agent-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let home = directory.appendingPathComponent("home", isDirectory: true)
    let sources = directory.appendingPathComponent("skills", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    for name in AgentSkillInstaller.skillNames {
        let skill = sources.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Test skill.\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }
    let legacy = home.appendingPathComponent(".agents/AGENTS.md")
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "before\n<!-- PORTLYBAR AGENT RULES START -->\nold\n<!-- PORTLYBAR AGENT RULES END -->\nafter\n".write(
        to: legacy,
        atomically: true,
        encoding: .utf8
    )

    let first = try AgentSkillInstaller.synchronize(sourceRoot: sources, homeDirectory: home)
    #expect(first.installed.count == 4)
    #expect(first.legacyRulesRemoved)
    #expect(try String(contentsOf: legacy, encoding: .utf8) == "before\n\nafter\n")

    let second = try AgentSkillInstaller.synchronize(sourceRoot: sources, homeDirectory: home)
    #expect(second.unchanged.count == 4)

    let managedSource = sources.appendingPathComponent("portlybar-http-server/SKILL.md")
    try "---\nname: portlybar-http-server\ndescription: Updated test skill.\n---\n".write(
        to: managedSource,
        atomically: true,
        encoding: .utf8
    )
    let third = try AgentSkillInstaller.synchronize(sourceRoot: sources, homeDirectory: home)
    #expect(third.updated.count == 2)

    let customized = home.appendingPathComponent(".codex/skills/portlybar-http-server/SKILL.md")
    try "local customization".write(to: customized, atomically: true, encoding: .utf8)
    try "---\nname: portlybar-http-server\ndescription: Another update.\n---\n".write(
        to: managedSource,
        atomically: true,
        encoding: .utf8
    )
    let fourth = try AgentSkillInstaller.synchronize(sourceRoot: sources, homeDirectory: home)
    #expect(fourth.conflicts == [home.appendingPathComponent(".codex/skills/portlybar-http-server").path])
    #expect(try String(contentsOf: customized, encoding: .utf8) == "local customization")
}

@Test func agentSkillSynchronizationTreatsExistingSymlinksAsConflicts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portlybar-agent-link-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let home = directory.appendingPathComponent("home", isDirectory: true)
    let sources = directory.appendingPathComponent("skills", isDirectory: true)
    let codexSkills = home.appendingPathComponent(".codex/skills", isDirectory: true)
    try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
    for name in AgentSkillInstaller.skillNames {
        let skill = sources.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Test skill.\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }
    let external = directory.appendingPathComponent("external-portlybar", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try "external".write(to: external.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let linkedDestination = codexSkills.appendingPathComponent("portlybar")
    try FileManager.default.createSymbolicLink(at: linkedDestination, withDestinationURL: external)

    let report = try AgentSkillInstaller.synchronize(sourceRoot: sources, homeDirectory: home)
    #expect(report.conflicts == [linkedDestination.path])
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkedDestination.path) == external.path)
    #expect(try String(contentsOf: external.appendingPathComponent("SKILL.md"), encoding: .utf8) == "external")
}
