#if DEBUG
import AppKit
import QuartzCore
import WestieKit

/// RunLoop active spans exclude sleeping. A >50ms span is a responsiveness proxy,
/// not proof of a single continuous stack or a display hitch in an occluded window.
extension Notification.Name {
    static let westiePerfQuery = Notification.Name("westie.perfQuery")
}

@MainActor enum PerfMonitor {
    static var launchSnapshot: Snapshot?
    private static var observer: CFRunLoopObserver?
    private static var activeSince: Double?
    private static var spans: [(Double, Double)] = []

    static func install() {
        guard PerfTrace.enabled, observer == nil else { return }
        launchSnapshot = snapshot()
        PerfTrace.mark("app_init", ["pid": Double(getpid())])
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated {
                let now = PerfTrace.clock()
                if activity == .afterWaiting {
                    activeSince = now
                } else if let start = activeSince {
                    if now - start > 0.05 {
                        spans.append((start, now - start))
                        PerfTrace.mark("runloop_busy", ["start": start, "ms": (now - start) * 1000])
                    }
                    activeSince = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    struct Snapshot {
        let time: Double
        let cpu: Double
        let mainCPU: Double
        let counts: [String: Double]
    }

    static func snapshot() -> Snapshot {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1e6 }
        // THREAD_BASIC_INFO for the calling (main) thread; release the Mach send right.
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        var info = thread_basic_info()
        var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
        }
        let mainCPU = result == KERN_SUCCESS
            ? Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6 : 0
        return Snapshot(time: PerfTrace.clock(), cpu: seconds(usage.ru_utime) + seconds(usage.ru_stime), mainCPU: mainCPU, counts: PerfTrace.counters())
    }

    static func finish(_ name: String, since start: Snapshot) {
        guard PerfTrace.enabled else { return }
        let end = snapshot()
        let duration = end.time - start.time
        var observed = spans
        if let activeSince, end.time - activeSince > 0.05 { observed.append((activeSince, end.time - activeSince)) }
        let relevant = observed.filter { $0.0 + $0.1 > start.time && $0.0 <= end.time }
        var fields = end.counts.mapValues { $0 }
        for (key, value) in start.counts { fields[key, default: 0] -= value }
        fields["ms"] = duration * 1000
        fields["cpu_pct"] = (end.cpu - start.cpu) / max(duration, 0.001) * 100
        fields["main_cpu_pct"] = (end.mainCPU - start.mainCPU) / max(duration, 0.001) * 100
        fields["busy_over_50ms"] = Double(relevant.count)
        fields["busy_max_ms"] = (relevant.map { $0.1 }.max() ?? 0) * 1000
        fields["rss_mb"] = residentMB()
        PerfTrace.mark(name, fields)
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size) }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1
    }

    /// Wait for counter/geometry quietness over 3 checks, max 8s. Does not activate,
    /// force display, synthesize input or treat a fixed animation delay as render time.
    @discardableResult static func settle() async -> Bool {
        var last = PerfTrace.counters()
        var stable = 0
        let deadline = PerfTrace.clock() + 8
        while PerfTrace.clock() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            let next = PerfTrace.counters()
            if next == last { stable += 1 } else { stable = 0 }
            if stable >= 3 { return true }
            last = next
        }
        PerfTrace.mark("settle_timeout")
        return false
    }
}
#endif
