// The menu bar app: holds the power assertion and decides when the Mac should stay awake.
import Cocoa
import IOKit.pwr_mgt
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Level { case none, system, display }
    struct Hold { var until: Date; var pid: pid_t? }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let d = UserDefaults.standard
    private let tracker = AgentTracker()
    private var assertionID: IOPMAssertionID = 0
    private var level: Level = .none
    private var holds: [String: Hold] = [:]
    private var agents: [AgentTracker.Agent] = []
    private var autoSince: Date?
    private var paused: String?
    private var summary = ""
    private var detail: String?
    private var tickTimer: Timer?
    private var jiggleTimer: Timer?
    private var lastCommandID: String?

    // MARK: Settings

    private var manualOn: Bool { get { d.bool(forKey: "awake") } set { d.set(newValue, forKey: "awake") } }
    private var manualUntil: Date? { get { d.object(forKey: "until") as? Date } set { d.set(newValue, forKey: "until") } }
    private var agentMode: Bool { get { d.bool(forKey: "agentMode") } set { d.set(newValue, forKey: "agentMode") } }
    private var agentScreen: Bool { get { d.bool(forKey: "agentScreen") } set { d.set(newValue, forKey: "agentScreen") } }
    private var ignoreIdle: Bool { get { d.bool(forKey: "ignoreIdle") } set { d.set(newValue, forKey: "ignoreIdle") } }
    private var pluggedInOnly: Bool { get { d.bool(forKey: "pluggedInOnly") } set { d.set(newValue, forKey: "pluggedInOnly") } }
    private var maxHours: Int { get { d.integer(forKey: "maxHours") } set { d.set(newValue, forKey: "maxHours") } }
    private var watched: [String] { get { d.stringArray(forKey: "watched") ?? Awake.defaultAgents } set { d.set(newValue, forKey: "watched") } }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        d.register(defaults: ["agentMode": true, "ignoreIdle": true, "pluggedInOnly": true, "maxHours": 12, "agentScreen": false])
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(onCommand(_:)), name: Awake.commandNote,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        if d.bool(forKey: "jiggle") { startJiggle(prompt: false) }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        setLevel(.none, reason: "")
        try? FileManager.default.removeItem(at: Awake.statusURL)
    }

    private func tick() {
        agents = agentMode ? tracker.scan(watched: watched, ignoreIdle: ignoreIdle) : []
        update()
    }

    // MARK: Decide

    private func update() {
        let now = Date()
        if let u = manualUntil, u <= now { manualOn = false; manualUntil = nil }
        holds = holds.filter { _, h in h.until > now && (h.pid.map { kill($0, 0) == 0 || errno == EPERM } ?? true) }

        let working = agents.filter(\.working)
        let autoWanted = !working.isEmpty || !holds.isEmpty
        if !autoWanted { autoSince = nil } else if autoSince == nil { autoSince = now }

        paused = nil
        if autoWanted && !manualOn {
            if pluggedInOnly && Procs.onBattery() { paused = "Paused: on battery" }
            else if maxHours > 0, let s = autoSince, now.timeIntervalSince(s) > Double(maxHours) * 3600 { paused = "Stopped after the \(maxHours) h limit" }
        }
        let auto = autoWanted && paused == nil

        // What's keeping the Mac awake, in words.
        var reasons: [String] = []
        if !working.isEmpty {
            let names = Array(Set(working.map(\.name))).sorted().joined(separator: ", ")
            reasons.append(working.count == 1 ? "1 agent working (\(names))" : "\(working.count) agents working (\(names))")
        }
        if !holds.isEmpty { reasons.append(holds.count == 1 ? "1 task (\(holds.keys.first!))" : "\(holds.count) tasks") }

        if manualOn {
            summary = manualUntil.map { "Keeping awake until \(formatTime($0))" } ?? "Keeping awake"
            detail = reasons.isEmpty ? nil : reasons.joined(separator: " · ")
            setLevel(.display, reason: summary)
        } else if auto {
            summary = reasons.joined(separator: " · ")
            detail = agentScreen ? "Screen stays on" : "Screen can turn off, Mac stays awake"
            setLevel(agentScreen ? .display : .system, reason: summary)
        } else {
            summary = paused ?? "Off: Mac sleeps normally"
            detail = paused != nil ? reasons.joined(separator: " · ") : (agentMode ? "Watching for agents" : nil)
            setLevel(.none, reason: "")
        }
        refreshIcon()
        writeStatus()
    }

    private func setLevel(_ new: Level, reason: String) {
        if new == level, new == .none { return }
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
        level = new
        let type: String
        switch new {
        case .none: return
        case .system: type = kIOPMAssertionTypePreventUserIdleSystemSleep
        case .display: type = kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
        IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Awake: \(reason)" as CFString, &assertionID)
    }

    // MARK: Commands from the `awake` CLI

    @objc private func onCommand(_ note: Notification) {
        guard let s = note.object as? String, let c = try? Awake.decoder.decode(Command.self, from: Data(s.utf8)) else { return }
        let now = Date()
        switch c.action {
        case "on":
            manualOn = true
            manualUntil = c.minutes.map { now.addingTimeInterval(Double($0) * 60) }
        case "off":
            manualOn = false; manualUntil = nil; holds.removeAll()
        case "hold":
            let minutes = c.minutes ?? (maxHours > 0 ? maxHours * 60 : 24 * 60)
            holds[c.name ?? "task"] = Hold(until: now.addingTimeInterval(Double(minutes) * 60), pid: c.pid)
        case "release":
            holds[c.name ?? "task"] = nil
        case "agent-mode":
            agentMode = c.flag ?? true
        case "agents-add":
            watched = Array(Set(watched + (c.values ?? []))).sorted()
        case "agents-remove":
            let drop = Set(c.values ?? []); watched = watched.filter { !drop.contains($0) }
        case "agents-reset":
            d.removeObject(forKey: "watched")
        default: break   // ping
        }
        lastCommandID = c.id
        if c.action.hasPrefix("agent") { tick() } else { update() }
    }

    private func writeStatus() {
        let s = Status(pid: getpid(), version: Awake.version, updated: Date(), lastCommandID: lastCommandID,
                       awake: level != .none, screenOn: level == .display, summary: summary, paused: paused,
                       manual: manualOn, manualUntil: manualUntil, agentMode: agentMode,
                       agents: agents.map { AgentInfo(name: $0.name, pid: $0.pid, working: $0.working, cpuPercent: $0.cpuPercent) },
                       holds: holds.map { HoldInfo(name: $0.key, until: $0.value.until, pid: $0.value.pid) }.sorted { $0.name < $1.name },
                       watched: watched, onlyWhenPluggedIn: pluggedInOnly, maxHours: maxHours,
                       keepScreenOnForAgents: agentScreen, ignoreIdleAgents: ignoreIdle)
        try? FileManager.default.createDirectory(at: Awake.supportDir, withIntermediateDirectories: true)
        try? Awake.encoder.encode(s).write(to: Awake.statusURL, options: .atomic)
    }

    // MARK: Menu

    private func refreshIcon() {
        let symbol: String
        switch level {
        case .none: symbol = "cup.and.saucer"
        case .system: symbol = "cup.and.heat.waves.fill"
        case .display: symbol = "cup.and.saucer.fill"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Awake")
        statusItem.button?.toolTip = "Awake: " + summary
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(label(summary, bold: true))
        if let detail, !detail.isEmpty { menu.addItem(label(detail)) }
        menu.addItem(.separator())

        menu.addItem(item("Keep Awake", #selector(toggleAwake), on: manualOn && manualUntil == nil, key: "a"))
        let forMenu = NSMenu()
        for (title, mins) in [("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)] {
            forMenu.addItem(item(title, #selector(awakeFor(_:)), tag: mins))
        }
        menu.addItem(submenu("Keep Awake For", forMenu, on: manualUntil != nil))
        menu.addItem(.separator())

        menu.addItem(item("Stay Awake While Agents Work", #selector(toggleAgentMode), on: agentMode))
        let s = NSMenu()
        s.addItem(item("Keep Screen On", #selector(toggleAgentScreen), on: agentScreen))
        s.addItem(item("Ignore Idle Agents (10 min)", #selector(toggleIgnoreIdle), on: ignoreIdle))
        s.addItem(item("Only When Plugged In", #selector(togglePluggedIn), on: pluggedInOnly))
        let limit = NSMenu()
        for h in [4, 8, 12, 24, 0] { limit.addItem(item(h == 0 ? "No Limit" : "\(h) hours", #selector(setLimit(_:)), on: maxHours == h, tag: h)) }
        s.addItem(submenu("Stop After", limit))
        s.addItem(.separator())
        s.addItem(item("Watched Agents…", #selector(editWatched)))
        if !agents.isEmpty {
            s.addItem(.separator())
            for a in agents { s.addItem(label("\(a.name) (\(a.pid)): \(a.working ? "working" : "idle"), \(a.cpuPercent)% CPU")) }
        }
        menu.addItem(submenu("Agent Settings", s))
        menu.addItem(.separator())

        menu.addItem(item("Jiggle Mouse", #selector(toggleJiggle), on: jiggleTimer != nil, key: "j"))
        menu.addItem(.separator())
        menu.addItem(item("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Install Command Line Tool…", #selector(installCLI)))
        menu.addItem(item("Awake on GitHub", #selector(openGitHub)))
        menu.addItem(NSMenuItem(title: "Quit Awake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false, tag: Int = 0, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self; i.tag = tag; i.state = on ? .on : .off
        return i
    }
    private func submenu(_ title: String, _ sub: NSMenu, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.submenu = sub; i.state = on ? .on : .off; return i
    }
    private func label(_ text: String, bold: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: ""); i.isEnabled = false
        if bold { i.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)]) }
        return i
    }

    // MARK: Actions

    @objc private func toggleAwake() { manualOn = !(manualOn && manualUntil == nil); manualUntil = nil; update() }
    @objc private func awakeFor(_ sender: NSMenuItem) { manualOn = true; manualUntil = Date().addingTimeInterval(Double(sender.tag) * 60); update() }
    @objc private func toggleAgentMode() { agentMode.toggle(); tick() }
    @objc private func toggleAgentScreen() { agentScreen.toggle(); update() }
    @objc private func toggleIgnoreIdle() { ignoreIdle.toggle(); tick() }
    @objc private func togglePluggedIn() { pluggedInOnly.toggle(); update() }
    @objc private func setLimit(_ sender: NSMenuItem) { maxHours = sender.tag; update() }
    @objc private func openGitHub() { NSWorkspace.shared.open(Awake.repoURL) }

    @objc private func editWatched() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = watched.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Watched Agents"
        alert.informativeText = "Process names that count as AI agents, separated by commas. Awake keeps the Mac awake while any of them is working."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Reset to Defaults")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            watched = field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case .alertThirdButtonReturn: d.removeObject(forKey: "watched")
        default: return
        }
        tick()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            show("Couldn't change Open at Login", "Add Awake under System Settings → General → Login Items instead.\n\n\(error.localizedDescription)")
        }
    }

    @objc private func installCLI() {
        guard let exe = Bundle.main.executablePath, !exe.contains("'"), !exe.contains("\"") else { return }
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(exe)' /usr/local/bin/awake\" with prompt \"Awake wants to install the awake command.\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) != -128 { show("Couldn't install the command", "\(err[NSAppleScript.errorMessage] ?? "")") }
        } else {
            show("Command installed", "Open Terminal and try:\n\nawake status\nawake run -- your-long-command\nawake help")
        }
    }

    private func show(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    // MARK: Mouse jiggle (keeps chat apps "Active"; needs Accessibility permission)

    @objc private func toggleJiggle() { jiggleTimer == nil ? startJiggle(prompt: true) : stopJiggle() }

    private func startJiggle(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            if prompt { show("Allow Accessibility", "To move the mouse, enable Awake in System Settings → Privacy & Security → Accessibility, then turn Jiggle Mouse on again.") }
            return
        }
        d.set(true, forKey: "jiggle")
        jiggleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            // Only nudge when you've been idle, so it never fights your real mouse.
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            guard idle > 25, let pos = CGEvent(source: nil)?.location else { return }
            for p in [CGPoint(x: pos.x + 1, y: pos.y), pos] {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
    }

    private func stopJiggle() { jiggleTimer?.invalidate(); jiggleTimer = nil; d.set(false, forKey: "jiggle") }
}
