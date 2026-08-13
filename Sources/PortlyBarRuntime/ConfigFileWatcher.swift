import Darwin
import Foundation

public final class ConfigFileWatcher: @unchecked Sendable {
    private let directory: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.portlybar.config-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var debounce: DispatchWorkItem?

    public init(configFile: URL, onChange: @escaping @Sendable () -> Void) {
        self.directory = configFile.deletingLastPathComponent()
        self.onChange = onChange
    }

    public func start() throws {
        guard source == nil else { return }
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw NSError(
                domain: "PortlyBarConfigWatcher",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Unable to watch configuration directory \(directory.path): \(String(cString: strerror(errno)))"]
            )
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            self.debounce = work
            self.queue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        self.source = source
        source.activate()
    }

    public func stop() {
        debounce?.cancel()
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
