// The `awake` command-line tool. Same binary as the app; talks to the running app via
// distributed notifications and reads its status file. `awake run` works even without the app.
import Foundation
import IOKit.pwr_mgt

enum CLI {
    static let commands: Set<String> = ["help", "--help", "-h", "version", "--version", "status", "on", "off", "run", "hold", "release", "hook", "agents"]

    static let usage = """
    awake: keep your Mac awake while you (or your AI agents) work.

    Usage:
      awake status [--json]           What's keeping the Mac awake right now
      awake on [DURATION]             Keep awake (screen on), e.g. `awake on`, `awake on 2h`, `awake on 90m`
      awake off                       Stop keeping awake (clears `on` and all holds)
      awake run [--screen] -- CMD...  Keep awake exactly while CMD runs, then exit with its code
      awake hold NAME [DURATION]      Keep awake until `awake release NAME` (default: the app's time limit)
      awake release NAME
      awake agents                    List watched agent names and running agents
      awake agents add|remove NAME... Change which process names count as agents
      awake agents reset              Back to the default list
      awake agents on|off             Turn agent mode on or off
      awake hook start|end            For Claude Code hooks (reads the hook's JSON on stdin)
      awake version

    The screen may turn off while agents, holds and `run` keep the Mac awake (use --screen to keep it on).
    """

    static func main(_ args: [String]) -> Int32 {
        var args = args
        let cmd = args.isEmpty ? "status" : args.removeFirst()
        switch cmd {
        case "help", "--help", "-h": print(usage); return 0
        case "version", "--version": print("awake \(Awake.version)"); return 0
        case "status": return status(json: args.contains("--json"))

        case "on":
            var c = Command(action: "on")
            if let a = args.first { guard let m = minutes(a) else { return fail("Can't read duration '\(a)'. Try 30m, 2h or 1h30m.") }; c.minutes = m }
            return report(send(c))
        case "off":
            guard Status.read() != nil else { print("Awake isn't running, so nothing is keeping the Mac awake."); return 0 }
            return report(send(Command(action: "off")))

        case "hold":
            guard let name = args.first else { return fail("Usage: awake hold NAME [DURATION]") }
            var c = Command(action: "hold", name: name)
            if args.count > 1 { guard let m = minutes(args[1]) else { return fail("Can't read duration '\(args[1])'.") }; c.minutes = m }
            return report(send(c))
        case "release":
            guard let name = args.first else { return fail("Usage: awake release NAME") }
            guard Status.read() != nil else { return 0 }
            return report(send(Command(action: "release", name: name)))

        case "run": return run(args)
        case "hook": hook(args.first ?? ""); return 0   // never fail a hook

        case "agents":
            switch args.first {
            case nil: return agents()
            case "add", "remove":
                let names = Array(args.dropFirst())
                guard !names.isEmpty else { return fail("Usage: awake agents \(args[0]) NAME...") }
                guard send(Command(action: "agents-\(args[0])", values: names)) != nil else { return fail(noApp) }
                return agents()
            case "reset":
                guard send(Command(action: "agents-reset")) != nil else { return fail(noApp) }
                return agents()
            case "on", "off":
                return report(send(Command(action: "agent-mode", flag: args[0] == "on")))
            default: return fail("Usage: awake agents [add|remove NAME...|reset|on|off]")
            }
        default:
            return fail("Unknown command '\(cmd)'.\n\n\(usage)")
        }
    }

    // MARK: Commands

    private static func status(json: Bool) -> Int32 {
        guard let s = Status.read() else {
            if json { print(#"{"running": false}"#) } else { print("Awake isn't running. Open it, or use `awake run -- CMD`.") }
            return json ? 0 : 1
        }
        if json { print(String(decoding: try! Awake.encoder.encode(s), as: UTF8.self)); return 0 }
        print("\(s.awake ? "☕ Awake" : "💤 Not keeping awake"): \(s.summary)")
        if s.awake { print("   Screen: \(s.screenOn ? "stays on" : "can turn off")") }
        if s.manual { print("   Keep Awake: on\(s.manualUntil.map { " until \(formatTime($0))" } ?? "")") }
        for h in s.holds { print("   Hold: \(h.name) (until \(formatTime(h.until)))") }
        print("   Agent mode: \(s.agentMode ? "on" : "off")\(s.agentMode ? agentSettings(s) : "")")
        for a in s.agents { print("   • \(a.name) (pid \(a.pid)): \(a.working ? "working" : "idle"), \(a.cpuPercent)% CPU") }
        return 0
    }

    private static func agentSettings(_ s: Status) -> String {
        var parts: [String] = []
        if s.onlyWhenPluggedIn { parts.append("plugged in only") }
        parts.append(s.maxHours > 0 ? "stops after \(s.maxHours) h" : "no time limit")
        if s.ignoreIdleAgents { parts.append("ignores idle agents") }
        return " (" + parts.joined(separator: ", ") + ")"
    }

    private static func agents() -> Int32 {
        guard let s = Status.read() else { return fail(noApp) }
        print("Agent mode: \(s.agentMode ? "on" : "off")")
        print("Watching: \(s.watched.joined(separator: ", "))")
        if s.agents.isEmpty { print("No agents running.") }
        for a in s.agents { print("• \(a.name) (pid \(a.pid)): \(a.working ? "working" : "idle"), \(a.cpuPercent)% CPU") }
        return 0
    }

    /// Hold a power assertion of our own while a child command runs. Works without the app.
    private static func run(_ args: [String]) -> Int32 {
        var args = args
        var screen = false
        while let f = args.first, f.hasPrefix("-") {
            args.removeFirst()
            if f == "--" { break } else if f == "--screen" { screen = true } else { return fail("Unknown option \(f)") }
        }
        guard !args.isEmpty else { return fail("Usage: awake run [--screen] -- CMD [ARGS...]") }

        var assertion = IOPMAssertionID(0)
        let type = screen ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "awake run: \(args[0])" as CFString, &assertion)
        defer { IOPMAssertionRelease(assertion) }
        let holdName = "run \((args[0] as NSString).lastPathComponent) (\(getpid()))"
        if Status.read() != nil { post(Command(action: "hold", name: holdName, minutes: 7 * 24 * 60, pid: getpid())) }  // show it in the menu
        defer { if Status.read() != nil { post(Command(action: "release", name: holdName)) } }

        // Spawn the command with default signal handling; Ctrl-C reaches it directly through the terminal.
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        var sigs = sigset_t(); sigemptyset(&sigs)
        for s in [SIGINT, SIGQUIT, SIGTERM, SIGHUP] { sigaddset(&sigs, s) }
        posix_spawnattr_setsigdefault(&attr, &sigs)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))
        signal(SIGINT, SIG_IGN); signal(SIGQUIT, SIG_IGN)

        let cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) }; posix_spawnattr_destroy(&attr) }
        var child: pid_t = 0
        let err = posix_spawnp(&child, args[0], nil, &attr, cargs, environ)
        guard err == 0 else { return fail("Can't run '\(args[0])': \(String(cString: strerror(err)))", code: 127) }

        var st: Int32 = 0
        while waitpid(child, &st, 0) == -1 && errno == EINTR {}
        if st & 0x7f == 0 { return (st >> 8) & 0xff }   // exited normally
        return 128 + (st & 0x7f)                          // killed by a signal
    }

    /// Claude Code hooks: UserPromptSubmit → start, Stop/SessionEnd → end.
    private static func hook(_ phase: String) {
        var session = "session"
        if isatty(0) == 0,
           let obj = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
           let id = obj["session_id"] as? String { session = String(id.prefix(8)) }
        let name = "claude \(session)"
        switch phase {
        case "start":
            // Tie the hold to the agent process, so it ends even if the agent crashes.
            let watched = Set((Status.read()?.watched ?? Awake.defaultAgents).map { $0.lowercased() })
            var pid = getppid(), agentPID: pid_t? = nil, hops = 0
            while pid > 1, hops < 32 {
                if Procs.names(pid, comm: "").contains(where: { watched.contains($0.lowercased()) }) { agentPID = pid; break }
                guard let p = Procs.parent(of: pid) else { break }
                pid = p; hops += 1
            }
            if Status.read() != nil { post(Command(action: "hold", name: name, pid: agentPID)) }
            else { _ = send(Command(action: "hold", name: name, pid: agentPID)) }   // starts the app
        case "end":
            if Status.read() != nil { post(Command(action: "release", name: name)) }
        default: break
        }
    }

    // MARK: Talking to the app

    private static let noApp = "Couldn't reach the Awake app. Is it installed in Applications?"

    private static func post(_ c: Command) {
        DistributedNotificationCenter.default().postNotificationName(
            Awake.commandNote, object: String(decoding: try! Awake.encoder.encode(c), as: UTF8.self), userInfo: nil, deliverImmediately: true)
    }

    /// Send a command and wait for the app to confirm it. Starts the app if needed.
    private static func send(_ c: Command) -> Status? {
        if Status.read() == nil {
            guard launchApp() else { return nil }
        }
        post(c)
        for _ in 0..<40 {
            if let s = Status.read(), s.lastCommandID == c.id { return s }
            usleep(100_000)
        }
        return nil
    }

    private static func launchApp() -> Bool {
        // The CLI is usually a symlink into Awake.app/Contents/MacOS; find the bundle from the real path.
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        var size = UInt32(path.count)
        _NSGetExecutablePath(&path, &size)
        let exe = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", Awake.bundleID]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        for _ in 0..<50 { if Status.read() != nil { return true }; usleep(100_000) }
        return false
    }

    private static func report(_ s: Status?) -> Int32 {
        guard let s else { return fail(noApp) }
        print("\(s.awake ? "☕" : "💤") \(s.summary)")
        return 0
    }

    private static func minutes(_ text: String) -> Int? {
        if let n = Int(text) { return n > 0 ? n : nil }   // plain number = minutes
        var total = 0, num = ""
        for ch in text.lowercased() {
            if ch.isNumber { num.append(ch) }
            else if let n = Int(num), ch == "h" || ch == "m" { total += ch == "h" ? n * 60 : n; num = "" }
            else { return nil }
        }
        return num.isEmpty && total > 0 ? total : nil
    }

    private static func fail(_ msg: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data((msg + "\n").utf8)); return code
    }
}
