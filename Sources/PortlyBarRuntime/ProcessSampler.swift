import Foundation
import PortlyBarCore

public enum ProcessSampler {
    public static func sampleTree(rootPID: Int32) -> ProcessMetrics? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,%cpu=,rss="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        struct Row { let pid: Int32; let parent: Int32; let cpu: Double; let rssKB: UInt64 }
        let rows: [Row] = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 4,
                  let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  let cpu = Double(fields[2]), let rss = UInt64(fields[3]) else { return nil }
            return Row(pid: pid, parent: parent, cpu: cpu, rssKB: rss)
        }
        var included: Set<Int32> = [rootPID]
        var changed = true
        while changed {
            changed = false
            for row in rows where included.contains(row.parent) && !included.contains(row.pid) {
                included.insert(row.pid)
                changed = true
            }
        }
        let selected = rows.filter { included.contains($0.pid) }
        guard !selected.isEmpty else { return nil }
        let bytes = selected.reduce(UInt64(0)) { $0 + $1.rssKB * 1_024 }
        return ProcessMetrics(
            cpuPercent: selected.reduce(0) { $0 + $1.cpu },
            residentBytes: bytes,
            footprintBytes: bytes
        )
    }
}
