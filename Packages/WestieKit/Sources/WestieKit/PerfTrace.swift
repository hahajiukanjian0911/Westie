import Foundation

/// Opt-in DEBUG measurement only. No clock, allocations or logging on the disabled path.
public enum PerfTrace {
    #if DEBUG
    public static let enabled = ProcessInfo.processInfo.environment["WESTIE_PERF_LOG"] != nil
    private static let state = State()
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Double] = [:]
        var handle: FileHandle?
        init() {
            guard let path = ProcessInfo.processInfo.environment["WESTIE_PERF_LOG"] else { return }
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = try? FileHandle(forWritingTo: URL(filePath: path))
        }
    }
    #else
    public static let enabled = false
    #endif

    @inline(__always) public static func clock() -> Double {
        guard enabled else { return 0 }
        return ProcessInfo.processInfo.systemUptime
    }

    public static func count(_ key: String, by value: Double = 1) {
        #if DEBUG
        guard enabled else { return }
        state.lock.withLock { state.counts[key, default: 0] += value }
        #endif
    }

    public static func mark(_ name: String, _ fields: [String: Double] = [:]) {
        #if DEBUG
        guard enabled else { return }
        state.lock.withLock {
            var record: [String: Any] = ["name": name, "uptime": clock(), "wall": Date().timeIntervalSince1970]
            record.merge(fields.mapValues { $0 as Any }) { _, new in new }
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                state.handle?.write(data + Data([10]))
            }
        }
        #endif
    }

    public static func counters() -> [String: Double] {
        #if DEBUG
        guard enabled else { return [:] }
        return state.lock.withLock { state.counts }
        #else
        return [:]
        #endif
    }
}
