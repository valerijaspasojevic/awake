// Finds running AI agents and measures how busy they are. Uses only public libproc/sysctl APIs.
import Darwin
import Foundation
import IOKit.ps

struct ProcInfo { let pid: pid_t; let ppid: pid_t; let names: [String] }

enum Procs {
    private static let timebase: Double = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()
    private static let argMax: Int = { var v: Int32 = 0; var s = MemoryLayout<Int32>.size; var mib = [CTL_KERN, KERN_ARGMAX]; sysctl(&mib, 2, &v, &s, nil, 0); return Int(v) }()
    private static let interpreters: Set<String> = ["node", "bun", "deno", "npx", "ruby", "python", "python3"]

    /// All processes owned by the current user.
    static func list() -> [ProcInfo] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let uid = getuid()
        return pids.prefix(Int(max(count, 0))).compactMap { pid in
            guard pid > 0, let info = bsdInfo(pid), info.pbi_uid == uid else { return nil }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return ProcInfo(pid: pid, ppid: pid_t(info.pbi_ppid), names: names(pid, comm: comm))
        }
    }

    static func parent(of pid: pid_t) -> pid_t? { bsdInfo(pid).map { pid_t($0.pbi_ppid) } }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// Names a process goes by: its short name, argv[0], and argv[1] when argv[0] is an interpreter (node, python…).
    static func names(_ pid: pid_t, comm: String) -> [String] {
        var out = [comm]
        let a = args(pid, limit: 2)
        if let a0 = a.first {
            let b = (a0 as NSString).lastPathComponent
            out.append(b)
            if a.count > 1, interpreters.contains(b) || b.hasPrefix("python") { out.append((a[1] as NSString).lastPathComponent) }
        }
        return out
    }

    private static func args(_ pid: pid_t, limit: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // executable path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var out: [String] = []
        while out.count < min(argc, limit) && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    /// Total CPU seconds a process has used so far.
    static func cpuSeconds(_ pid: pid_t) -> Double? {
        var ri = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard r == 0 else { return nil }
        return Double(ri.ri_user_time + ri.ri_system_time) * timebase / 1e9
    }

    static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }
}

/// Tracks agent processes between scans and decides which ones are actually working.
/// An agent counts as working while its whole process tree (agent + tools it runs) averages
/// at least `threshold` CPU over the last `window`; after `grace` without work it counts as idle.
final class AgentTracker {
    struct Agent { let pid: pid_t; let name: String; var working: Bool; var cpuPercent: Double }

    static let window: TimeInterval = 120
    static let threshold = 0.04         // 4% of one core
    static let grace: TimeInterval = 600

    private var lastCPU: [pid_t: Double] = [:]
    private var samples: [pid_t: [(start: Date, end: Date, used: Double)]] = [:]
    private var lastBusy: [pid_t: Date] = [:]
    private var lastScan: Date?

    func scan(watched: [String], ignoreIdle: Bool) -> [Agent] {
        let now = Date()
        let wanted = Set(watched.map { $0.lowercased() })
        let me = getpid()
        var parent: [pid_t: pid_t] = [:], kids: [pid_t: [pid_t]] = [:], match: [pid_t: String] = [:]
        for p in Procs.list() {
            parent[p.pid] = p.ppid
            kids[p.ppid, default: []].append(p.pid)
            if p.pid != me, let n = p.names.first(where: { wanted.contains($0.lowercased()) }) { match[p.pid] = n }
        }
        // Report only the top-most agent process (e.g. a node wrapper and the binary it starts count once).
        func underAnotherAgent(_ pid: pid_t) -> Bool {
            var q = parent[pid], hops = 0
            while let x = q, x > 1, hops < 64 { if match[x] != nil { return true }; q = parent[x]; hops += 1 }
            return false
        }

        var newCPU: [pid_t: Double] = [:]
        var result: [Agent] = []
        for (root, name) in match where !underAnotherAgent(root) {
            let known = lastBusy[root] != nil
            var used = 0.0, stack = [root]
            while let pid = stack.popLast() {
                if let c = Procs.cpuSeconds(pid) {
                    newCPU[pid] = c
                    if let old = lastCPU[pid] { used += max(0, c - old) } else if known { used += c }  // new child process
                }
                stack += kids[pid] ?? []
            }
            if !known { lastBusy[root] = now }   // newly seen agents start out as working
            var s = samples[root] ?? []
            if let prev = lastScan, known { s.append((prev, now, used)) }
            s.removeAll { now.timeIntervalSince($0.end) > Self.window }
            samples[root] = s
            var rate = 0.0
            if let first = s.first {
                rate = s.reduce(0) { $0 + $1.used } / max(1, now.timeIntervalSince(first.start))
                if rate >= Self.threshold { lastBusy[root] = now }
            }
            let working = !ignoreIdle || now.timeIntervalSince(lastBusy[root]!) < Self.grace
            result.append(Agent(pid: root, name: name, working: working, cpuPercent: (rate * 1000).rounded() / 10))
        }
        let alive = Set(result.map(\.pid))
        lastBusy = lastBusy.filter { alive.contains($0.key) }
        samples = samples.filter { alive.contains($0.key) }
        lastCPU = newCPU
        lastScan = now
        return result.sorted { $0.pid < $1.pid }
    }
}
