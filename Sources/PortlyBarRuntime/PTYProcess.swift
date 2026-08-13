import Darwin
import Foundation
import SwiftTerm

public protocol PTYProcessDelegate: AnyObject {
    func ptyProcess(_ process: PTYProcess, received bytes: ArraySlice<UInt8>)
    func ptyProcess(_ process: PTYProcess, terminatedWith exitCode: Int32?)
}

public final class PTYProcess: NSObject, LocalProcessDelegate, @unchecked Sendable {
    public weak var delegate: PTYProcessDelegate?
    private let callbackQueue: DispatchQueue
    private var process: LocalProcess?

    public init(delegate: PTYProcessDelegate, callbackQueue: DispatchQueue = .main) {
        self.delegate = delegate
        self.callbackQueue = callbackQueue
    }

    public var pid: Int32? {
        guard let value = process?.shellPid, value > 0 else { return nil }
        return value
    }

    public var isRunning: Bool { process?.running == true }

    public func start(command: String, directory: String, environment: [String: String]) throws {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: directory) else {
            throw NSError(
                domain: "PortlyBarPTY",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Working directory does not exist: \(directory)"]
            )
        }
        let local = LocalProcess(delegate: self, dispatchQueue: callbackQueue)
        process = local
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        local.startProcess(
            executable: "/bin/zsh",
            args: ["-lc", command],
            environment: env,
            currentDirectory: directory
        )
        guard local.running else {
            process = nil
            throw NSError(
                domain: "PortlyBarPTY",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to start command in a pseudo-terminal: \(command)"]
            )
        }
    }

    public func terminate(force: Bool = false) {
        guard let pid else { return }
        let signal = force ? SIGKILL : SIGTERM
        // SwiftTerm creates a session for the child. Signal its whole process group
        // so file watchers and shell descendants do not remain orphaned.
        if Darwin.kill(-pid, signal) != 0 {
            _ = Darwin.kill(pid, signal)
        }
    }

    public func send(_ text: String) {
        process?.send(data: Array(text.utf8)[...])
    }

    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        delegate?.ptyProcess(self, terminatedWith: normalizedExitCode(exitCode))
        process = nil
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
        delegate?.ptyProcess(self, received: slice)
    }

    public func getWindowSize() -> winsize {
        winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    }

    private func normalizedExitCode(_ raw: Int32?) -> Int32? {
        guard let raw else { return nil }
        let signal = raw & 0x7f
        if signal == 0 { return (raw >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return raw
    }
}
